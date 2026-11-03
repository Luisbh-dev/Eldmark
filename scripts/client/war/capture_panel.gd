class_name CapturePanel
extends PanelContainer
## Panel de captura del fuerte (UI-18, docs/fuerte.md sección 6): dueño con su color y emblema, fase,
## barra de progreso con el color del captor, «disputado», jugadores presentes de cada bando en el
## círculo, vida de la puerta y si el fuerte está atacado.
## [br][br]
## [b]Cuándo se ve.[/b] A menos de [constant NEAR_DISTANCE] m del fuerte, o combatiendo a menos de
## [constant COMBAT_DISTANCE] m ([method should_show]); en cualquier otro caso se oculta. El resto de
## UI-18 (los banners de aviso, la barra de jefe y la marca de los ataques) vive en [WarBanners],
## [BossBar] y [TelegraphMarks].
## [br][br]
## [b]De dónde sale.[/b] [method bind] lo conecta con la [FortressView] (estado en pantalla y progreso
## con la fórmula en el instante de dibujo) y el [NetClient] (posición, combate y tick); cada
## fotograma [method refresh] pregunta y llama a [method show_state]. [method show_state] es la parte
## pura (un [FortressState] y unos números en, textos y barras fuera): las pruebas la usan con estados
## falsos.
## [br][br]
## Todas las medidas, colores y textos de aquí son provisionales: la presentación definitiva
## (ART-17, UI-02) es del usuario. Solo cliente.

## Metros del fuerte a los que se ve el panel, y a los que se ve combatiendo.
const NEAR_DISTANCE: float = 80.0
const COMBAT_DISTANCE: float = 200.0
const PANEL_WIDTH: float = 440.0
const TOP_MARGIN: float = 44.0
const EMBLEM_SIZE: float = 30.0
## Parpadeos por segundo de «Disputado».
const CONTESTED_BLINK_HERTZ: float = 1.5
const GATE_COLOR: Color = Color(0.66, 0.46, 0.26, 1.0)
const GATE_BROKEN_COLOR: Color = Color(0.45, 0.2, 0.18, 1.0)
const ATTACKED_COLOR: Color = Color(1.0, 0.45, 0.3, 1.0)

const TEXT_NO_OWNER: String = "Sin dueño (los Huecos)"
const TEXT_OWNER: String = "Dueño: %s"
const TEXT_ATTACKED: String = "¡Atacado!"
const TEXT_GARRISONED: String = "Guarnición y capitán en pie"
const TEXT_GARRISONED_OWN: String = "Guarnición y capitán en pie: defiéndelo"
const TEXT_VULNERABLE: String = "Capitán caído: entra en el círculo para capturar"
const TEXT_VULNERABLE_OWN: String = "Capitán caído: defiende el círculo"
const TEXT_CAPTURING: String = "%s captura el fuerte"
const TEXT_CONSOLIDATING: String = "Consolidando: llega la guarnición"
const TEXT_CONTESTED: String = "Disputado"
const TEXT_FROZEN: String = "Congelado"
const TEXT_RETREATING: String = "Retrocede"
const TEXT_PRESENT: String = "En el círculo:"
const TEXT_GATE: String = "Puerta %d / %d"
const TEXT_GATE_BROKEN: String = "Puerta derribada"
const TEXT_PROGRESS: String = "%d %%"

var _view: FortressView = null
var _client: NetClient = null
var _own_realm: int = NetProtocol.Realm.NONE
var _fortress_id: int = 0
var _shown: bool = false
var _last_progress: float = 0.0
var _contested_clock: float = 0.0

var _emblem: TextureRect = null
var _title: Label = null
var _owner: Label = null
var _attacked: Label = null
var _phase: Label = null
var _status: Label = null
var _progress: FractionBar = null
var _present_row: HBoxContainer = null
var _present_title: Label = null
var _present_labels: Array[Label] = []
var _gate: FractionBar = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_built()
	visible = _shown


func _process(delta: float) -> void:
	refresh(delta)


## Conecta el panel con la vista del fuerte ([param view]) y el cliente ([param client], para saber
## dónde está el jugador, si combate y en qué tick va el servidor) y el reino del jugador
## ([param own_realm], un [enum NetProtocol.Realm]).
func bind(view: FortressView, client: NetClient, own_realm: int) -> void:
	_view = view
	_client = client
	_own_realm = own_realm
	_fortress_id = 0
	_ensure_built()


## Cada fotograma: decide si se ve y, si es así, lo pinta con el estado en pantalla de la fortaleza.
## [param delta] mueve el parpadeo de «disputado».
func refresh(delta: float = 0.0) -> void:
	_contested_clock += delta
	if not is_instance_valid(_view):
		_set_shown(false)
		return
	if _fortress_id == 0 or not _view.has_fortress(_fortress_id):
		_fortress_id = _view.get_primary_id()
	var state: FortressState = _view.get_displayed_state(_fortress_id) if _fortress_id != 0 else null
	if state == null:
		_set_shown(false)
		return
	var distance: float = _distance_to_fortress()
	var in_combat: bool = is_instance_valid(_client) and _client.is_in_combat()
	if not should_show(distance, in_combat):
		_set_shown(false)
		return
	var definition: FortressDefinition = _view.get_definition(_fortress_id)
	var fortress_name: String = definition.display_name if definition != null else "Fuerte"
	var estimated_tick: int = _client.get_estimated_server_tick() if is_instance_valid(_client) else 0
	show_state(state, _view.get_progress_fraction_now(_fortress_id), fortress_name, estimated_tick)
	if _status.visible and _status.text == TEXT_CONTESTED:
		# «Disputado» parpadea.
		_status.modulate.a = 0.65 + 0.35 * sin(_contested_clock * TAU * CONTESTED_BLINK_HERTZ)
	_set_shown(true)


## true si el panel debe verse a [param distance] metros del fuerte ([constant Vector3.INF] si no se
## sabe dónde está) [param in_combat].
static func should_show(distance: float, in_combat: bool) -> bool:
	if not is_finite(distance):
		return false
	return distance <= NEAR_DISTANCE or (in_combat and distance <= COMBAT_DISTANCE)


## Pinta [param state]: [param progress_fraction] es el progreso de la captura (0 a 1) en el instante
## de dibujo, [param fortress_name] el nombre del fuerte y [param estimated_tick] el tick del
## servidor, para saber si está «atacado». No decide si se ve ([method refresh]).
func show_state(state: FortressState, progress_fraction: float, fortress_name: String,
		estimated_tick: int = 0) -> void:
	_ensure_built()
	_title.text = fortress_name
	var owner_color: Color = UIPalette.faction_color_of_code(state.owner)
	_owner.text = _owner_text(state.owner)
	_owner.add_theme_color_override(&"font_color", owner_color)
	_emblem.texture = UIPalette.load_emblem(RealmCatalog.id_of_code(state.owner))
	_emblem.modulate = owner_color
	_emblem.visible = _emblem.texture != null
	_attacked.visible = state.under_attack_until_tick > estimated_tick and estimated_tick > 0
	_phase.text = phase_text(state, _own_realm)
	var status: String = status_text(state)
	_status.text = status
	_status.visible = not status.is_empty()
	_status.modulate.a = 1.0
	var capturing: bool = state.phase == FortressState.Phase.CAPTURING
	_progress.visible = capturing
	_last_progress = clampf(progress_fraction, 0.0, 1.0) if capturing else 0.0
	_progress.set_fraction(_last_progress)
	_progress.fill_color = UIPalette.faction_color_of_code(state.capture_realm)
	_progress.text = TEXT_PROGRESS % roundi(_last_progress * 100.0)
	_show_presence(state)
	_show_gate(state)


## Texto de la fase para un jugador del reino [param own_realm].
static func phase_text(state: FortressState, own_realm: int) -> String:
	var own: bool = own_realm != NetProtocol.Realm.NONE and state.owner == own_realm
	match state.phase:
		FortressState.Phase.GARRISONED:
			return TEXT_GARRISONED_OWN if own else TEXT_GARRISONED
		FortressState.Phase.VULNERABLE:
			return TEXT_VULNERABLE_OWN if own else TEXT_VULNERABLE
		FortressState.Phase.CAPTURING:
			return TEXT_CAPTURING % WarEvents.realm_label(state.capture_realm).capitalize()
		FortressState.Phase.CONSOLIDATING:
			return TEXT_CONSOLIDATING
	return ""


## Estado de la captura: «Disputado», «Congelado» (nadie la hace avanzar), «Retrocede» o vacío.
static func status_text(state: FortressState) -> String:
	if state.contested and (state.phase == FortressState.Phase.VULNERABLE \
			or state.phase == FortressState.Phase.CAPTURING):
		return TEXT_CONTESTED
	if state.phase == FortressState.Phase.CAPTURING:
		if state.capture_rate < 0:
			return TEXT_RETREATING
		if state.capture_rate == 0:
			return TEXT_FROZEN
	return ""


# --- Accesos (para las pruebas y para quien monta la interfaz) --------------------------------

## true si el panel se está mostrando.
func is_shown() -> bool:
	return _shown


func get_title_text() -> String:
	return _title.text if _title != null else ""


func get_owner_text() -> String:
	return _owner.text if _owner != null else ""


func get_owner_color() -> Color:
	return _owner.get_theme_color(&"font_color") if _owner != null else Color.WHITE


func get_phase_text() -> String:
	return _phase.text if _phase != null else ""


func get_status_text() -> String:
	return _status.text if _status != null and _status.visible else ""


func is_attacked_shown() -> bool:
	return _attacked != null and _attacked.visible


func is_progress_shown() -> bool:
	return _progress != null and _progress.visible


func get_progress_fraction() -> float:
	return _last_progress


func get_progress_color() -> Color:
	return _progress.fill_color if _progress != null else Color.WHITE


func get_progress_text() -> String:
	return _progress.text if _progress != null else ""


func is_presence_shown() -> bool:
	return _present_row != null and _present_row.visible


## Texto del recuento de presentes de un bando (código de red 1 a 3) o vacío si no se muestra.
func get_presence_text(realm_code: int) -> String:
	var label: Label = _present_label(realm_code)
	return label.text if label != null and label.visible else ""


func get_presence_color(realm_code: int) -> Color:
	var label: Label = _present_label(realm_code)
	return label.get_theme_color(&"font_color") if label != null else Color.WHITE


func get_gate_text() -> String:
	return _gate.text if _gate != null else ""


func get_gate_fraction() -> float:
	return _gate.get_fraction() if _gate != null else 0.0


func is_gate_shown() -> bool:
	return _gate != null and _gate.visible


func get_gate_color() -> Color:
	return _gate.fill_color if _gate != null else Color.WHITE


# --- Interno ----------------------------------------------------------------------------------

func _set_shown(shown: bool) -> void:
	_shown = shown
	visible = shown


func _owner_text(owner_realm: int) -> String:
	if owner_realm == RealmCatalog.NEUTRAL_CODE:
		return TEXT_NO_OWNER
	return TEXT_OWNER % WarEvents.realm_label(owner_realm)


func _distance_to_fortress() -> float:
	if _fortress_id == 0 or not is_instance_valid(_view) or not is_instance_valid(_client):
		return INF
	var anchor: Vector3 = _view.get_anchor_position(_fortress_id)
	var character: PlayerCharacter = _client.get_character()
	if anchor == Vector3.INF or character == null or not is_instance_valid(character):
		return INF
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	return Vector2(here.x - anchor.x, here.z - anchor.z).length()


# Presentes de cada bando en el círculo (solo con el círculo activo). Vardheim y Solmarch siempre;
# Askarra solo si hay alguien o es el reino del jugador.
func _show_presence(state: FortressState) -> void:
	var active: bool = state.is_circle_active()
	_present_row.visible = active
	if not active:
		return
	for realm: int in range(1, FortressFields.PRESENCE_REALMS):
		var label: Label = _present_label(realm)
		var count: int = state.presence[realm]
		label.visible = realm != NetProtocol.Realm.ASKARRA or count > 0 or realm == _own_realm
		label.text = "%s %d" % [WarEvents.realm_label(realm).capitalize(), count]
		label.add_theme_color_override(&"font_color", UIPalette.faction_color_of_code(realm))


func _show_gate(state: FortressState) -> void:
	_gate.visible = state.gate_max > 0
	if state.gate_max <= 0:
		return
	var broken: bool = state.is_gate_broken()
	_gate.set_fraction(float(state.gate_health) / float(state.gate_max))
	_gate.fill_color = GATE_BROKEN_COLOR if broken else GATE_COLOR
	_gate.text = TEXT_GATE_BROKEN if broken else TEXT_GATE % [state.gate_health, state.gate_max]


func _present_label(realm_code: int) -> Label:
	var index: int = realm_code - 1
	if index < 0 or index >= _present_labels.size():
		return null
	return _present_labels[index]


func _ensure_built() -> void:
	if _title == null:
		_build()


func _build() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	# Centrado arriba (UI-49): con el preset de tamaño mínimo quedaba con el borde izquierdo en el centro.
	UILayout.anchor_top_center(self, PANEL_WIDTH, TOP_MARGIN)
	var column := VBoxContainer.new()
	column.name = "Columna"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 4)
	add_child(column)
	var head := HBoxContainer.new()
	head.name = "Cabecera"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override(&"separation", 8)
	column.add_child(head)
	_emblem = TextureRect.new()
	_emblem.name = "Emblema"
	_emblem.custom_minimum_size = Vector2(EMBLEM_SIZE, EMBLEM_SIZE)
	_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_emblem)
	var names := VBoxContainer.new()
	names.name = "Nombres"
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	_title = _make_label("Titulo", 18)
	names.add_child(_title)
	_owner = _make_label("Dueno", 15)
	names.add_child(_owner)
	_attacked = _make_label("Atacado", 16)
	_attacked.text = TEXT_ATTACKED
	_attacked.add_theme_color_override(&"font_color", ATTACKED_COLOR)
	_attacked.visible = false
	head.add_child(_attacked)
	_phase = _make_label("Fase", 15)
	column.add_child(_phase)
	_status = _make_label("Estado", 15)
	_status.add_theme_color_override(&"font_color", UIPalette.WARNING)
	_status.visible = false
	column.add_child(_status)
	_progress = FractionBar.new()
	_progress.name = "Progreso"
	_progress.custom_minimum_size = Vector2(0.0, 18.0)
	_progress.font_size = 14
	_progress.visible = false
	column.add_child(_progress)
	_present_row = HBoxContainer.new()
	_present_row.name = "Presentes"
	_present_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_present_row.add_theme_constant_override(&"separation", 14)
	_present_row.visible = false
	column.add_child(_present_row)
	_present_title = _make_label("TituloPresentes", 14)
	_present_title.text = TEXT_PRESENT
	_present_row.add_child(_present_title)
	for realm: int in range(1, FortressFields.PRESENCE_REALMS):
		var label := _make_label("Presentes%d" % realm, 14)
		_present_labels.append(label)
		_present_row.add_child(label)
	_gate = FractionBar.new()
	_gate.name = "Puerta"
	_gate.custom_minimum_size = Vector2(0.0, 14.0)
	_gate.font_size = 12
	_gate.fill_color = GATE_COLOR
	_gate.visible = false
	column.add_child(_gate)


func _make_label(label_name: String, font_size: int) -> Label:
	var label := Label.new()
	label.name = label_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_outline_color", UIPalette.OUTLINE)
	label.add_theme_constant_override(&"outline_size", 4)
	return label
