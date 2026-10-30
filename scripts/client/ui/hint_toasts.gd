class_name HintToasts
extends Control
## Pistas del juego (UI-42, docs/fuerte.md sección 6): consejos cortos ([HintCatalog]) que salen abajo, sobre
## la línea de ayuda de controles, una sola vez por jugador ([HintLog], en [code]user://[/code]) y solo si
## las pistas están activadas en los ajustes ([constant ClientSettings.HINTS]).
## [br][br]
## [b]Qué las dispara.[/b] Eventos del cliente: un aviso de guerra de capitán caído ([signal
## NetClient.war_event]) o un TELEGRAPH ([signal NetClient.telegraph_received]) de quien puede dañar al jugador
## ([method TelegraphMarks.threatens], la misma regla que dibuja la marca) a menos de su radio más
## [constant TELEGRAPH_DISTANCE] m; y cosas que se miran cada
## [constant POLL_SECONDS] ([method poll]): estar ya dentro del mundo (los controles de combate y los del
## mapa y el marcador), estar cerca del fuerte (el panel de
## captura se ve) o a menos de [constant GATE_DISTANCE] m de una puerta cerrada para tu reino. La pantalla
## de muerte pide [constant HintCatalog.RESPAWN_MAP] con [method request] y la retira al cerrarse
## ([method withdraw]).
## [br][br]
## [b]Cola.[/b] Se enseña una pista cada vez, [constant SHOW_SECONDS] s con fundido, y entre una y otra pasan
## [constant GAP_SECONDS] s. La del TELEGRAPH caduca con su marca: si no le llega el turno antes, se descarta.
## [br][br]
## [b]Vista de verdad.[/b] El [HUD] las monta por encima de la pantalla de muerte (sin atenuar) y por debajo del
## mapa y del marcador, y le da [member is_covered]: mientras el mapa o el marcador las tapan no sale ninguna, y la
## que se veía vuelve a la cabeza de la cola si aún no se había leído. Una pista solo se anota como vista
## ([HintLog]) tras [constant MIN_SEEN_SECONDS] s en pantalla sin tapar, o al quitarla con [method dismiss] (se acaba
## su tiempo o se desactivan las pistas); si se desactivan con alguna en cola, se descartan sin anotarse (revisión
## de la fase 4, cliente). Medidas, textos y tiempos provisionales. Solo cliente.

const SHOW_SECONDS: float = 9.0
const FADE_SECONDS: float = 1.0
const GAP_SECONDS: float = 2.0
const POLL_SECONDS: float = 0.5
## Segundos en pantalla, sin tapar, tras los que una pista cuenta como vista.
const MIN_SEEN_SECONDS: float = 4.0
## Metros de una puerta cerrada para tu reino a los que sale la pista de la puerta.
const GATE_DISTANCE: float = 15.0
## Metros, más allá del radio de la marca, hasta los que un TELEGRAPH da su pista.
const TELEGRAPH_DISTANCE: float = 20.0
## Segundos de más (tras el impacto) que espera en la cola la pista de un TELEGRAPH.
const TELEGRAPH_GRACE_SECONDS: float = 0.5
const WIDTH: float = 640.0
const BOTTOM_OFFSET: float = 84.0
const FONT_SIZE: int = 18
const TEXT_TITLE: String = "Pista"

## [code]() -> bool[/code]: true mientras algo tapa las pistas (el mapa, el marcador). Lo da el [HUD].
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
# Segundos que lleva la actual a la vista y si ya se ha anotado.
var _seen: float = 0.0
var _noted: bool = false
# Pista en cola -> segundos que le quedan para salir antes de caducar (las que no caducan no están).
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


## Conecta las pistas con el cliente (sus avisos y dónde está el jugador), la vista del fuerte y el panel de
## captura (para saber si se está cerca), los ajustes ([param settings], por defecto los del jugador) y el
## registro de pistas vistas ([param hint_log], por defecto el del jugador).
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


## true si las pistas están activadas en los ajustes.
func is_enabled() -> bool:
	return _settings == null or bool(_settings.get_value(ClientSettings.HINTS))


## Pide la pista [param id]. Se pone en cola si el catálogo la conoce, las pistas están activadas, el
## jugador no la ha visto ya y no está ya en cola o en pantalla. Con [param lifetime] mayor que 0, si no ha salido
## en ese tiempo se descarta sin anotarse (lo que la motivaba ya no está). Devuelve true si se ha puesto en cola.
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


## Retira la pista [param id] porque ya no viene a cuento (la de reaparecer, al cerrarse la pantalla de muerte): sale
## de la cola y, si se está viendo y aún no se ha leído, se quita sin anotarse. Se puede volver a pedir.
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


## Avanza [param delta] segundos: el tiempo en pantalla, el fundido, la pausa entre pistas y la caducidad de las que
## esperan.
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
			# Tapada antes de leerla: vuelve la primera de la cola y sale en cuanto se destape.
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


## Quita la pista de la pantalla y la da por vista (la siguiente sale tras la pausa).
func dismiss() -> void:
	if _current == &"":
		return
	if not _noted:
		_note_current()
	_hide_current()
	_gap = GAP_SECONDS


## Mira lo que dispara pistas sin evento: estar en el mundo, cerca del fuerte o de una puerta cerrada.
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


# --- Accesos (para las pruebas) ---------------------------------------------------------------

func get_current_id() -> StringName:
	return _current


func get_current_text() -> String:
	return _body.text if _body != null and _current != &"" else ""


func get_queued_ids() -> Array[StringName]:
	return _queue.duplicate()


func get_seconds_left() -> float:
	return _left


## Cuántas pistas han salido en pantalla desde que existe.
func get_shown_total() -> int:
	return _shown_total


func is_showing() -> bool:
	return _panel != null and _panel.visible


## El panel de la pista.
func get_panel() -> PanelContainer:
	_ensure_built()
	return _panel


# --- Interno ----------------------------------------------------------------------------------

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


# Un TELEGRAPH da su pista si es de quien puede dañar al jugador y cae cerca; caduca con la marca.
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


# Al desactivar las pistas, lo que esperaba en cola se descarta (y no se anota como visto).
func _on_setting_changed(id: StringName, value: Variant) -> void:
	if id == ClientSettings.HINTS and not bool(value):
		_queue.clear()
		_deadlines.clear()
		dismiss()


func _covered() -> bool:
	return is_covered.is_valid() and bool(is_covered.call())


# Descuenta [param delta] a las pistas en cola que caducan y descarta (sin anotarlas) las que ya no van a salir.
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


# true si hay una puerta enteramente cerrada para el reino del jugador a menos de GATE_DISTANCE m.
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
