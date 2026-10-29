class_name DeathScreen
extends Control
## Pantalla de muerte y reaparición (UI-14). Se abre al morir y enseña quién te derrotó y con qué,
## la cuenta atrás hasta que el servidor deja reaparecer, la lista de puntos de reaparición y el
## botón «Reaparecer», que solo se habilita cuando ya se puede y envía el punto elegido
## ([signal respawn_requested]). Al reaparecer se cierra y no deja nada atrás.
## [br][br]
## No lee la red: el [HUD] la abre con [method open], la actualiza cada fotograma con
## [method update_countdown] (con el tick del servidor estimado por [NetClient]) y la cierra con
## [method close]. La cuenta se hace en ticks del servidor, así que va sincronizada con la
## reaparición real aunque el reloj local se desfase. Los nodos se crean una sola vez en
## [method _ready] y abrirla y cerrarla solo cambia textos y visibilidad: morir y reaparecer muchas
## veces no acumula nada.

## El jugador pide reaparecer en el punto [param point_index] de la lista.
signal respawn_requested(point_index: int)
## El jugador pide ver el mapa para elegir el punto de reaparición.
signal map_requested
## La pantalla se ha abierto o cerrado.
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
## Segundos sin que reaparezca el jugador tras pedirlo, pasados los cuales el botón se vuelve a
## habilitar (el servidor no contesta a una petición fuera de plazo).
const REQUEST_TIMEOUT_SECONDS: float = 2.0

var _open: bool = false
# Índice que se envía por cada fila de la lista (vacío = el de la fila).
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


func _ready() -> void:
	# Cubre la pantalla y se come el ratón mientras está abierta (el cursor está libre).
	mouse_filter = Control.MOUSE_FILTER_STOP
	_ensure_built()
	visible = _open


## Abre la pantalla. [param cause_text] es la frase de quién te derrotó (ver [method
## CombatText.death_text]), [param respawn_tick] el tick del servidor en el que se puede reaparecer
## y [param point_labels] los nombres de los puntos de reaparición, en el orden de la lista cuyo
## índice se envía al servidor. Si ya estaba abierta, solo actualiza.
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


## Avanza [param delta] segundos la espera de la respuesta a una petición de reaparición: si el
## servidor no la atiende en [constant REQUEST_TIMEOUT_SECONDS] s, el botón vuelve a habilitarse.
func advance(delta: float) -> void:
	if not _open or not _requested:
		return
	_request_age += delta
	if _request_age >= REQUEST_TIMEOUT_SECONDS:
		_requested = false
		update_countdown(_estimated_tick)


## Cambia la lista de puntos (la de [method open]) sin cerrar la pantalla: el estado de los fuertes
## cambia mientras se espera. Conserva el punto elegido si sigue en la lista.
func update_points(point_labels: PackedStringArray, indices: PackedInt32Array = PackedInt32Array()) -> void:
	_ensure_built()
	var previous: int = get_selected_point_index()
	var had_previous: bool = not _point_indices.is_empty() or _points.item_count > 0
	_set_points(point_labels)
	set_point_indices(indices)
	if had_previous:
		select_point_index(previous)


## Índice que se envía en la petición por cada fila de la lista (el de la lista de todos los marcadores
## de reaparición de la zona, ver [RespawnPointList.Option.index_for]). Sin llamarla, el de la fila.
func set_point_indices(indices: PackedInt32Array) -> void:
	_point_indices = indices


## Índice que se enviaría ahora: el de la fila elegida, pasado por [method set_point_indices] si lo hay.
func get_selected_point_index() -> int:
	var row: int = get_selected_point()
	if row >= 0 and row < _point_indices.size():
		return _point_indices[row]
	return row


## Elige la fila cuyo índice enviado es [param point_index] (si está en la lista). Devuelve false si no.
func select_point_index(point_index: int) -> bool:
	for row: int in get_point_count():
		var sent: int = _point_indices[row] if row < _point_indices.size() else row
		if sent == point_index:
			select_point(row)
			return true
	return false


## Cambia la frase de quién te derrotó (el evento puede llegar con la pantalla ya abierta).
func set_cause_text(text: String) -> void:
	_ensure_built()
	_cause.text = text


## Cierra la pantalla (al reaparecer) y deja todo como estaba.
func close() -> void:
	if not _open:
		return
	_open = false
	_requested = false
	visible = false
	_button.disabled = true
	closed.emit()


## Actualiza la cuenta atrás con el tick del servidor [param estimated_server_tick] (ver
## [method NetClient.get_estimated_server_tick]). El botón se habilita cuando ese tick alcanza el de
## reaparición.
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


## Ticks que faltan para poder reaparecer (0 si ya se puede).
func get_remaining_ticks() -> int:
	return maxi(_respawn_tick - _estimated_tick, 0)


## Segundos enteros (hacia arriba) que faltan para poder reaparecer.
func get_remaining_seconds() -> int:
	return ceili(float(get_remaining_ticks()) / float(Engine.physics_ticks_per_second))


## true si el botón está habilitado.
func is_respawn_enabled() -> bool:
	return _button != null and not _button.disabled


## Punto elegido en la lista (0 si no hay selección).
func get_selected_point() -> int:
	if _points == null:
		return 0
	var selected: PackedInt32Array = _points.get_selected_items()
	return selected[0] if not selected.is_empty() else 0


func select_point(index: int) -> void:
	if _points != null and index >= 0 and index < _points.item_count:
		_points.select(index)


## El botón «Elegir en el mapa» (visible mientras hay más de un punto donde elegir).
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


## El botón «Reaparecer»; las pruebas lo pulsan con [code]emit_signal("pressed")[/code].
func get_button() -> Button:
	return _button


## Nodos que cuelgan de la pantalla: no crece al abrirla y cerrarla.
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
	# La lista crece con los puntos, sin pasar de cinco filas visibles.
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
	column.add_child(_points)
	_map_button = Button.new()
	_map_button.name = "Mapa"
	_map_button.text = MAP_BUTTON_TEXT
	_map_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_map_button.pressed.connect(func() -> void: map_requested.emit())
	column.add_child(_map_button)
	_button = Button.new()
	_button.name = "Reaparecer"
	_button.text = BUTTON_TEXT
	_button.custom_minimum_size = Vector2(200.0, 48.0)
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.disabled = true
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
