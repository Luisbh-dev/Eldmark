class_name RealmSelect
extends Control
## Pantalla de elección de reino (docs/red.md, secciones 1.2 y 17.5; TEC-45).
## [br][br]
## Tres botones (Vardheim, Solmarch, Askarra), los campos de dirección del servidor y de nombre del
## personaje, un aviso y el botón «Entrar». [OnlineMain] la muestra cuando un modo en red arranca sin
## [code]--realm[/code] y vuelve a ella tras un rechazo o una desconexión, con el motivo en el aviso
## ([method set_notice]).
## [br][br]
## [b]Validación antes de conectar.[/b] El nombre se comprueba con [NameRules] mientras se escribe y
## el motivo (en español, [method NameRules.reason_text]) se muestra junto al campo; la dirección, con
## [method ClientConfig.parse_address]. «Entrar» solo se activa con un reino admitido elegido, un nombre
## válido y una dirección válida, y entonces emite [signal realm_chosen]. Los reinos que la zona no
## admite ([param allowed] de [method setup]) salen desactivados.
## [br][br]
## En modo [code]--local[/code] la dirección es siempre la de esta máquina: [method set_address_editable]
## desactiva ese campo.
## [br][br]
## [b]Recuento por reino (GUE-42, docs/fuerte.md sección 7).[/b] [method set_realm_counts] enseña bajo cada botón
## cuántos jugadores tiene su reino en la zona (el recuento que el servidor manda en el WELCOME) y marca el
## reino con menos jugadores como recomendado ([method get_recommended_realm]) para repartir la batalla. El
## WELCOME solo llega al conectar, así que el recuento es el de la última conexión (y no hay ninguno antes de
## la primera). Si el servidor rechaza el reino elegido por desequilibrio (REJECT 9, [constant
## NetProtocol.Result.IMBALANCE]) [method set_rejected_realm] lo quita de la elección y lo deja marcado.
## [br][br]
## [b]Plantilla de equipo[/b] (PRG-07, docs/habilidades.md, sección 6.5): bajo el nombre, el
## [TemplateSelector]. La elegida ([method get_selected_template]) la guarda [OnlineMain] en
## [member ClientConfig.loadout] y [NetClient] la manda en un LOADOUT_SELECT nada más llegar el WELCOME, así
## que vale ya para la primera aparición.

## Se emite al pulsar «Entrar» con todo válido: [param realm] es un código de
## [enum NetProtocol.Realm], [param address] el texto del campo de dirección
## ([code]host[/code] o [code]host:puerto[/code]) y [param display_name] el nombre ya sin espacios
## alrededor.
signal realm_chosen(realm: int, address: String, display_name: String)
## Se emite al pulsar «Salir».
signal quit_requested()

## Reinos jugables, en el orden de los botones.
const REALMS: Array[int] = [
	NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
]
const TEXT_PICK_REALM: String = "Elige un reino para entrar"
const TEXT_NOT_ALLOWED: String = "Este reino no puede entrar en la zona"
const TEXT_PLAYERS: String = "%d jugadores"
const TEXT_ONE_PLAYER: String = "1 jugador"
const TEXT_NO_PLAYERS: String = "Sin jugadores"
const TEXT_RECOMMENDED: String = "%s · recomendado"
const TEXT_REJECTED: String = "%s · completo"
const TEXT_FULL: String = "Completo"
const TEXT_COUNTS_NOTE: String = "Recuento de tu última conexión. Si un reino tiene muchos más jugadores, el servidor puede rechazarlo."
const TEXT_REJECTED_TOOLTIP: String = "El servidor ha rechazado este reino: tiene demasiados jugadores"
const RECOMMENDED_COLOR: Color = Color(0.55, 0.9, 0.55, 1.0)
const REJECTED_COLOR: Color = Color(1.0, 0.72, 0.4, 1.0)
const COUNT_COLOR: Color = Color(0.75, 0.78, 0.84, 1.0)

var _allowed: PackedInt32Array = PackedInt32Array()
var _default_address: String = "127.0.0.1"
var _default_name: String = ""
var _selected_realm: int = NetProtocol.Realm.NONE
var _address_editable: bool = true
var _notice: String = ""
var _configured: bool = false
var _group: ButtonGroup = ButtonGroup.new()
var _counts: PackedInt32Array = PackedInt32Array()
var _rejected_realm: int = NetProtocol.Realm.NONE
var _templates: TemplateSelector = null
var _pending_template: int = -1

@onready var _notice_label: Label = %NoticeLabel
@onready var _vardheim_button: Button = %VardheimButton
@onready var _solmarch_button: Button = %SolmarchButton
@onready var _askarra_button: Button = %AskarraButton
@onready var _vardheim_count: Label = %VardheimCount
@onready var _solmarch_count: Label = %SolmarchCount
@onready var _askarra_count: Label = %AskarraCount
@onready var _counts_note: Label = %CountsNote
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _name_edit: LineEdit = %NameEdit
@onready var _name_reason: Label = %NameReasonLabel
@onready var _hint_label: Label = %HintLabel
@onready var _enter_button: Button = %EnterButton
@onready var _quit_button: Button = %QuitButton


func _ready() -> void:
	for realm: int in REALMS:
		var button: Button = get_realm_button(realm)
		button.toggle_mode = true
		button.button_group = _group
		button.text = NetProtocol.realm_display_name(realm)
		var color: Color = RealmCatalog.color_of(RealmCatalog.id_of_code(realm))
		button.add_theme_color_override(&"font_color", color)
		button.add_theme_color_override(&"font_hover_color", color.lightened(0.25))
		button.add_theme_color_override(&"font_pressed_color", color.lightened(0.4))
		button.add_theme_color_override(&"font_focus_color", color.lightened(0.25))
		button.pressed.connect(_on_realm_pressed.bind(realm))
		button.toggled.connect(_on_realm_toggled.bind(realm))
	_address_edit.text_changed.connect(_on_text_changed)
	_name_edit.text_changed.connect(_on_text_changed)
	_name_edit.text_submitted.connect(_on_text_submitted)
	_address_edit.text_submitted.connect(_on_text_submitted)
	_enter_button.pressed.connect(_try_enter)
	_quit_button.pressed.connect(func() -> void: quit_requested.emit())
	_templates = TemplateSelector.new()
	var column: Node = _hint_label.get_parent()
	column.add_child(_templates)
	column.move_child(_templates, _hint_label.get_index())
	if _pending_template >= 0:
		_templates.select(_pending_template)
	_apply()


## Prepara la pantalla: [param default_address] y [param default_name] rellenan los campos y
## [param allowed] son los códigos de reino ([enum NetProtocol.Realm]) que admite la zona; vacío =
## todos ([method NetZones.allowed_realms]). Se puede llamar antes o después de añadirla al árbol.
## Deshace la elección de reino anterior si ya no está admitida.
func setup(default_address: String, default_name: String, allowed: PackedInt32Array) -> void:
	_default_address = default_address
	_default_name = default_name
	_allowed = allowed
	_configured = true
	if _selected_realm != NetProtocol.Realm.NONE and not is_realm_allowed(_selected_realm):
		_selected_realm = NetProtocol.Realm.NONE
	if is_node_ready():
		_apply()


## Aviso que se muestra encima del formulario (el motivo del último rechazo o corte). Vacío lo quita.
func set_notice(text: String) -> void:
	_notice = text
	if is_node_ready():
		_refresh()


## Activa o desactiva el campo de dirección (desactivado en modo [code]--local[/code]).
func set_address_editable(editable: bool) -> void:
	_address_editable = editable
	if is_node_ready():
		_address_edit.editable = editable
		_refresh()


## Elige [param realm] (si la zona lo admite), como si se pulsara su botón. Con
## [constant NetProtocol.Realm.NONE] quita la elección.
func select_realm(realm: int) -> void:
	if realm != NetProtocol.Realm.NONE and (not REALMS.has(realm) or not is_realm_allowed(realm)):
		return
	_selected_realm = realm
	if is_node_ready():
		_sync_buttons()
		_refresh()


## Reino elegido ([constant NetProtocol.Realm.NONE] si aún no hay).
func get_selected_realm() -> int:
	return _selected_realm


## true si la zona admite [param realm] (la lista de admitidos vacía admite todos).
func is_realm_allowed(realm: int) -> bool:
	return _allowed.is_empty() or _allowed.has(realm)


## Marca la plantilla de equipo [param template_id] (0 = la de por defecto). Se puede llamar antes de añadir
## la pantalla al árbol.
func set_selected_template(template_id: int) -> void:
	_pending_template = template_id
	if _templates != null:
		_templates.select(template_id)


## Plantilla de equipo elegida (id del catálogo de combate; la de por defecto si no se ha tocado).
func get_selected_template() -> int:
	if _templates != null:
		return _templates.get_selected()
	return _pending_template if _pending_template > 0 else CombatCatalog.default_template_id()


## El selector de plantilla de equipo (null antes de entrar en el árbol).
func get_template_selector() -> TemplateSelector:
	return _templates


## Botón del reino [param realm] (null si no es un reino jugable).
func get_realm_button(realm: int) -> Button:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return _vardheim_button
		NetProtocol.Realm.SOLMARCH:
			return _solmarch_button
		NetProtocol.Realm.ASKARRA:
			return _askarra_button
	return null


## Enseña el recuento por reino ([param counts]: jugadores de Vardheim, Solmarch y Askarra, como el
## [member NetMessages.Welcome.realm_counts]). Vacío (o de otro tamaño) quita el recuento.
func set_realm_counts(counts: PackedInt32Array) -> void:
	_counts = counts.duplicate() if counts.size() == REALMS.size() else PackedInt32Array()
	if is_node_ready():
		_refresh_counts()


## true si hay un recuento que enseñar.
func has_realm_counts() -> bool:
	return not _counts.is_empty()


## Jugadores del reino [param realm] según el recuento (-1 si no hay recuento o no es un reino jugable).
func get_realm_count(realm: int) -> int:
	var index: int = REALMS.find(realm)
	return _counts[index] if index >= 0 and not _counts.is_empty() else -1


## El reino admitido con menos jugadores: el que conviene elegir. [constant NetProtocol.Realm.NONE] si no hay
## recuento, si hay menos de dos reinos admitidos o si todos los admitidos van igualados. Con un empate en el
## mínimo, el primero en el orden de los botones.
func get_recommended_realm() -> int:
	if _counts.is_empty():
		return NetProtocol.Realm.NONE
	var best: int = NetProtocol.Realm.NONE
	var lowest: int = 0
	var highest: int = 0
	var allowed_count: int = 0
	for realm: int in REALMS:
		if not is_realm_allowed(realm):
			continue
		var count: int = get_realm_count(realm)
		if allowed_count == 0 or count < lowest:
			lowest = count
			best = realm
		highest = maxi(highest, count)
		allowed_count += 1
	return best if allowed_count >= 2 and highest > lowest else NetProtocol.Realm.NONE


## Texto del recuento bajo el botón de [param realm] (vacío si no hay recuento).
func get_count_text(realm: int) -> String:
	var label: Label = _count_label(realm)
	return label.text if label != null else ""


## El servidor ha rechazado [param realm] por desequilibrio (REJECT 9): se quita de la elección y se marca.
## Con [constant NetProtocol.Realm.NONE] se quita la marca.
func set_rejected_realm(realm: int) -> void:
	_rejected_realm = realm if REALMS.has(realm) else NetProtocol.Realm.NONE
	if _selected_realm == _rejected_realm and _rejected_realm != NetProtocol.Realm.NONE:
		_selected_realm = NetProtocol.Realm.NONE
	if is_node_ready():
		_sync_buttons()
		_refresh_counts()
		_refresh()


## Reino marcado como rechazado por desequilibrio ([constant NetProtocol.Realm.NONE] si ninguno).
func get_rejected_realm() -> int:
	return _rejected_realm


func get_enter_button() -> Button:
	return _enter_button


func get_quit_button() -> Button:
	return _quit_button


func get_address_edit() -> LineEdit:
	return _address_edit


func get_name_edit() -> LineEdit:
	return _name_edit


## Motivo, en español, por el que el nombre escrito no vale (vacío si vale).
func get_name_reason_text() -> String:
	return _name_reason.text


## Indicación bajo el formulario: qué falta para poder entrar (reino sin elegir o dirección
## no válida). Vacía si no falta nada.
func get_hint_text() -> String:
	return _hint_label.text


## Aviso que se muestra encima del formulario.
func get_notice_text() -> String:
	return _notice_label.text


## Emite [signal realm_chosen] si todo es válido (lo que hace «Entrar»). Devuelve true si lo emitió.
func try_enter() -> bool:
	if not _is_ready_to_enter():
		return false
	realm_chosen.emit(_selected_realm, _address_edit.text.strip_edges(),
			_name_edit.text.strip_edges())
	return true


# Rellena los campos y los botones con lo que dijo setup().
func _apply() -> void:
	if _configured:
		_address_edit.text = _default_address
		_name_edit.text = _default_name
	_address_edit.editable = _address_editable
	for realm: int in REALMS:
		var button: Button = get_realm_button(realm)
		var allowed: bool = is_realm_allowed(realm)
		button.disabled = not allowed
		button.tooltip_text = "" if allowed else TEXT_NOT_ALLOWED
	_sync_buttons()
	_refresh_counts()
	_refresh()
	_focus_first_control()


func _sync_buttons() -> void:
	for realm: int in REALMS:
		get_realm_button(realm).set_pressed_no_signal(realm == _selected_realm)


func _count_label(realm: int) -> Label:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return _vardheim_count
		NetProtocol.Realm.SOLMARCH:
			return _solmarch_count
		NetProtocol.Realm.ASKARRA:
			return _askarra_count
	return null


# Rellena los textos de recuento bajo los botones: jugadores, recomendado y rechazado.
func _refresh_counts() -> void:
	var recommended: int = get_recommended_realm()
	_counts_note.visible = has_realm_counts()
	_counts_note.text = TEXT_COUNTS_NOTE if has_realm_counts() else ""
	for realm: int in REALMS:
		var label: Label = _count_label(realm)
		var button: Button = get_realm_button(realm)
		button.tooltip_text = "" if is_realm_allowed(realm) else TEXT_NOT_ALLOWED
		if not has_realm_counts():
			# Sin recuento solo se marca el reino que el servidor ha rechazado.
			label.visible = realm == _rejected_realm
			label.text = TEXT_FULL if realm == _rejected_realm else ""
			label.add_theme_color_override(&"font_color", REJECTED_COLOR)
			if realm == _rejected_realm:
				button.tooltip_text = TEXT_REJECTED_TOOLTIP
			continue
		label.visible = true
		var count: int = get_realm_count(realm)
		var text: String = TEXT_NO_PLAYERS if count == 0 else (TEXT_ONE_PLAYER if count == 1 else TEXT_PLAYERS % count)
		var color: Color = COUNT_COLOR
		if realm == _rejected_realm:
			text = TEXT_REJECTED % text
			color = REJECTED_COLOR
		elif realm == recommended:
			text = TEXT_RECOMMENDED % text
			color = RECOMMENDED_COLOR
		label.text = text
		label.add_theme_color_override(&"font_color", color)
		if realm == _rejected_realm:
			button.tooltip_text = TEXT_REJECTED_TOOLTIP


# Textos y estado de «Entrar» según lo que hay escrito y elegido.
func _refresh() -> void:
	_notice_label.text = _notice
	_notice_label.visible = not _notice.is_empty()
	var reason: int = NameRules.validate(_name_edit.text.strip_edges())
	_name_reason.text = "" if reason == NameRules.Reason.OK else NameRules.reason_text(reason)
	var hint: String = ""
	if _selected_realm == NetProtocol.Realm.NONE:
		hint = TEXT_PICK_REALM
	elif _address_editable:
		hint = _address_error()
	_hint_label.text = hint
	_enter_button.disabled = not _is_ready_to_enter()


func _is_ready_to_enter() -> bool:
	if _selected_realm == NetProtocol.Realm.NONE or not is_realm_allowed(_selected_realm):
		return false
	if not NameRules.is_valid(_name_edit.text.strip_edges()):
		return false
	if _address_editable and not _address_error().is_empty():
		return false
	return true


# Motivo por el que la dirección escrita no vale (vacío si vale).
func _address_error() -> String:
	return String(ClientConfig.parse_address(_address_edit.text)["error"])


func _focus_first_control() -> void:
	if not is_inside_tree():
		return
	for realm: int in REALMS:
		var button: Button = get_realm_button(realm)
		if not button.disabled:
			button.grab_focus()
			return


func _on_realm_pressed(realm: int) -> void:
	select_realm(realm)


func _on_realm_toggled(pressed: bool, realm: int) -> void:
	if pressed:
		select_realm(realm)


func _on_text_changed(_text: String) -> void:
	_refresh()


func _on_text_submitted(_text: String) -> void:
	try_enter()


func _try_enter() -> void:
	try_enter()
