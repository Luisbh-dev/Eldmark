class_name ObjectiveLine
extends Control
## Línea de objetivo bajo la brújula (UI-54): una sola línea compacta y siempre visible con el estado del fuerte
## cuando se está lejos de él («Fuerte del Vado Gris · De Vardheim · Capitán del Vado en pie · Puerta 72 % · 182 m»).
## Sustituye al [CapturePanel], que solo aparece a menos de [constant CapturePanel.NEAR_DISTANCE] m (o de
## [constant CapturePanel.COMBAT_DISTANCE] m si se combate): la línea se esconde cuando el panel está a la vista, así
## que nunca hay las dos a la vez. Sin fuerte conocido no se dibuja. El texto sale de [method compose_text], pura.
## Solo cliente.

const WIDTH: float = 560.0
const HEIGHT: float = 22.0
## Debajo de la brújula (4 px de margen + 60 de alto) con un hueco.
const TOP_MARGIN: float = 68.0
const FONT_SIZE: int = 14
const BACK_COLOR: Color = Color(0.04, 0.045, 0.06, 0.55)
const TEXT_COLOR: Color = Color(0.93, 0.92, 0.88, 0.96)
const TEXT_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.8)
const SEPARATOR: String = " · "
const TEXT_CAPTAIN_UP: String = "Capitán del Vado en pie"
const TEXT_CAPTAIN_DOWN: String = "Capitán caído"
const TEXT_GATE: String = "Puerta %d %%"
const TEXT_GATE_BROKEN: String = "Puerta derribada"
const TEXT_CAPTURE: String = "Captura de %s: %d %%"
const TEXT_OWNER_NONE: String = "De los Huecos"
const TEXT_OWNER: String = "De %s"

var _client: NetClient = null
var _view: FortressView = null
var _panel: CapturePanel = null
var _text: String = ""


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(WIDTH, HEIGHT)
	visible = false


func _ready() -> void:
	UILayout.anchor_top_center(self, WIDTH, TOP_MARGIN)


func _process(_delta: float) -> void:
	refresh()


## Conecta la línea con el cliente (dónde está el jugador), la vista del fuerte y el panel de captura (que la sustituye
## cuando está a la vista).
func bind(client: NetClient, view: FortressView, panel: CapturePanel) -> void:
	_client = client
	_view = view
	_panel = panel
	refresh()


## Vuelve a calcular el texto y si se enseña.
func refresh() -> void:
	_text = ""
	var character: PlayerCharacter = _client.get_character() if is_instance_valid(_client) else null
	if not is_instance_valid(_view) or character == null or not is_instance_valid(character):
		_set_visible(false)
		return
	var net_id: int = _view.get_primary_id()
	var state: FortressState = _view.get_displayed_state(net_id) if net_id != 0 else null
	var anchor: Vector3 = _view.get_anchor_position(net_id) if net_id != 0 else Vector3.INF
	if state == null or anchor == Vector3.INF:
		_set_visible(false)
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	var distance: float = Vector2(anchor.x - here.x, anchor.z - here.z).length()
	var definition: FortressDefinition = _view.get_definition(net_id)
	_text = compose_text(definition.display_name if definition != null else "Fuerte", state,
			_view.get_progress_fraction_now(net_id), distance)
	_set_visible(not (is_instance_valid(_panel) and _panel.is_shown()))


## El texto que se está mostrando (vacío si la línea está oculta).
func get_text() -> String:
	return _text if visible else ""


## «Fuerte · De Vardheim · Capitán del Vado en pie · Puerta 72 % · 182 m» para un fuerte [param fort_name] en el
## estado [param state], con la captura al [param capture_fraction] (0 a 1) y a [param distance] m del jugador.
static func compose_text(fort_name: String, state: FortressState, capture_fraction: float, distance: float) -> String:
	var parts := PackedStringArray()
	parts.append(fort_name)
	parts.append(TEXT_OWNER_NONE if state.owner == RealmCatalog.NEUTRAL_CODE
			else TEXT_OWNER % WarEvents.realm_label(state.owner))
	if state.phase == FortressState.Phase.CAPTURING:
		parts.append(TEXT_CAPTURE % [WarEvents.realm_label(state.capture_realm).capitalize(),
				roundi(clampf(capture_fraction, 0.0, 1.0) * 100.0)])
	elif state.phase == FortressState.Phase.VULNERABLE:
		parts.append(TEXT_CAPTAIN_DOWN)
	elif state.phase == FortressState.Phase.GARRISONED:
		parts.append(TEXT_CAPTAIN_UP if state.captain_alive else TEXT_CAPTAIN_DOWN)
	if state.gate_max > 0:
		parts.append(TEXT_GATE_BROKEN if state.is_gate_broken()
				else TEXT_GATE % roundi(100.0 * float(state.gate_health) / float(state.gate_max)))
	parts.append("%d m" % roundi(distance))
	return SEPARATOR.join(parts)


func _set_visible(shown: bool) -> void:
	if visible != shown:
		visible = shown
	queue_redraw()


func _draw() -> void:
	if _text.is_empty():
		return
	var font: Font = get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, Vector2(WIDTH, HEIGHT)), BACK_COLOR)
	var text_size: Vector2 = font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE)
	var at := Vector2((WIDTH - text_size.x) * 0.5, HEIGHT * 0.5 + text_size.y * 0.3)
	draw_string_outline(font, at, _text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, 3, TEXT_OUTLINE)
	draw_string(font, at, _text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, TEXT_COLOR)
