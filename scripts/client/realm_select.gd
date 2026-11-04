class_name RealmSelect
extends Control
## Realm selection screen (docs/networking.md, sections 1.2 and 17.5; TEC-45).
## [br][br]
## Three buttons (Vardheim, Solmarch, Askarra), the server address and character name fields, a notice
## and the "Entrar" (Enter) button. [OnlineMain] shows it when a networked mode starts without
## [code]--realm[/code] and returns to it after a rejection or a disconnection, with the reason in the
## notice ([method set_notice]).
## [br][br]
## [b]Validation before connecting.[/b] The name is checked with [NameRules] as it is typed and the
## reason (in Spanish, [method NameRules.reason_text]) is shown next to the field; the address, with
## [method ClientConfig.parse_address]. "Entrar" is only enabled with a supported realm chosen, a valid
## name and a valid address, and then it emits [signal realm_chosen]. Realms the zone does not support
## ([param allowed] of [method setup]) appear disabled.
## [br][br]
## In [code]--local[/code] mode the address is always this machine's: [method set_address_editable]
## disables that field.
## [br][br]
## [b]Per-realm count (GUE-42, docs/fortress.md section 7).[/b] [method set_realm_counts] shows under each
## button how many players its realm has in the zone (the count the server sends in the WELCOME) and marks
## the realm with the fewest players as recommended ([method get_recommended_realm]) to spread out the
## battle. The WELCOME only arrives on connecting, so the count is that of the last connection (and there
## is none before the first). If the server rejects the chosen realm because of imbalance (REJECT 9, [constant
## NetProtocol.Result.IMBALANCE]), [method set_rejected_realm] removes it from the choice and
## leaves it marked.
## [br][br]
## [b]Loadout template[/b] (PRG-07, docs/abilities.md, section 6.5): under the name, the
## [TemplateSelector]. The chosen one ([method get_selected_template]) is stored by [OnlineMain] in
## [member ClientConfig.loadout] and [NetClient] sends it in a LOADOUT_SELECT as soon as the WELCOME
## arrives, so it is already valid for the first spawn.

## Emitted when "Entrar" is pressed with everything valid: [param realm] is a code from
## [enum NetProtocol.Realm], [param address] the text of the address field
## ([code]host[/code] or [code]host:port[/code]) and [param display_name] the name with the surrounding
## spaces already removed.
signal realm_chosen(realm: int, address: String, display_name: String)
## Emitted when "Salir" (Quit) is pressed.
signal quit_requested()

## Playable realms, in button order.
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


## Prepares the screen: [param default_address] and [param default_name] fill in the fields and
## [param allowed] are the realm codes ([enum NetProtocol.Realm]) the zone supports; empty = all
## ([method NetZones.allowed_realms]). It can be called before or after adding it to the tree.
## It undoes the previous realm choice if it is no longer supported.
func setup(default_address: String, default_name: String, allowed: PackedInt32Array) -> void:
	_default_address = default_address
	_default_name = default_name
	_allowed = allowed
	_configured = true
	if _selected_realm != NetProtocol.Realm.NONE and not is_realm_allowed(_selected_realm):
		_selected_realm = NetProtocol.Realm.NONE
	if is_node_ready():
		_apply()


## Notice shown above the form (the reason for the last rejection or disconnection). Empty removes it.
func set_notice(text: String) -> void:
	_notice = text
	if is_node_ready():
		_refresh()


## Enables or disables the address field (disabled in [code]--local[/code] mode).
func set_address_editable(editable: bool) -> void:
	_address_editable = editable
	if is_node_ready():
		_address_edit.editable = editable
		_refresh()


## Chooses [param realm] (if the zone supports it), as if its button were pressed. With
## [constant NetProtocol.Realm.NONE] it clears the choice.
func select_realm(realm: int) -> void:
	if realm != NetProtocol.Realm.NONE and (not REALMS.has(realm) or not is_realm_allowed(realm)):
		return
	_selected_realm = realm
	if is_node_ready():
		_sync_buttons()
		_refresh()


## Chosen realm ([constant NetProtocol.Realm.NONE] if none yet).
func get_selected_realm() -> int:
	return _selected_realm


## true if the zone supports [param realm] (an empty allowed list supports all).
func is_realm_allowed(realm: int) -> bool:
	return _allowed.is_empty() or _allowed.has(realm)


## Selects the loadout template [param template_id] (0 = the default one). It can be called before
## adding the screen to the tree.
func set_selected_template(template_id: int) -> void:
	_pending_template = template_id
	if _templates != null:
		_templates.select(template_id)


## Chosen loadout template (combat catalog id; the default one if untouched).
func get_selected_template() -> int:
	if _templates != null:
		return _templates.get_selected()
	return _pending_template if _pending_template > 0 else CombatCatalog.default_template_id()


## The loadout template selector (null before entering the tree).
func get_template_selector() -> TemplateSelector:
	return _templates


## Button of realm [param realm] (null if it is not a playable realm).
func get_realm_button(realm: int) -> Button:
	match realm:
		NetProtocol.Realm.VARDHEIM:
			return _vardheim_button
		NetProtocol.Realm.SOLMARCH:
			return _solmarch_button
		NetProtocol.Realm.ASKARRA:
			return _askarra_button
	return null


## Shows the per-realm count ([param counts]: players of Vardheim, Solmarch and Askarra, like
## [member NetMessages.Welcome.realm_counts]). Empty (or of another size) clears the count.
func set_realm_counts(counts: PackedInt32Array) -> void:
	_counts = counts.duplicate() if counts.size() == REALMS.size() else PackedInt32Array()
	if is_node_ready():
		_refresh_counts()


## true if there is a count to show.
func has_realm_counts() -> bool:
	return not _counts.is_empty()


## Players of realm [param realm] according to the count (-1 if there is no count or it is not a
## playable realm).
func get_realm_count(realm: int) -> int:
	var index: int = REALMS.find(realm)
	return _counts[index] if index >= 0 and not _counts.is_empty() else -1


## The supported realm with the fewest players: the one worth choosing. [constant NetProtocol.Realm.NONE]
## if there is no count, if fewer than two realms are supported or if all the supported ones are tied. With
## a tie at the minimum, the first in button order.
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


## Count text under the button of [param realm] (empty if there is no count).
func get_count_text(realm: int) -> String:
	var label: Label = _count_label(realm)
	return label.text if label != null else ""


## The server rejected [param realm] because of imbalance (REJECT 9): it is removed from the choice and
## marked. With [constant NetProtocol.Realm.NONE] the mark is cleared.
func set_rejected_realm(realm: int) -> void:
	_rejected_realm = realm if REALMS.has(realm) else NetProtocol.Realm.NONE
	if _selected_realm == _rejected_realm and _rejected_realm != NetProtocol.Realm.NONE:
		_selected_realm = NetProtocol.Realm.NONE
	if is_node_ready():
		_sync_buttons()
		_refresh_counts()
		_refresh()


## Realm marked as rejected because of imbalance ([constant NetProtocol.Realm.NONE] if none).
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


## Reason, in Spanish, why the typed name is not valid (empty if it is valid).
func get_name_reason_text() -> String:
	return _name_reason.text


## Hint under the form: what is missing before entering is possible (no realm chosen or invalid
## address). Empty if nothing is missing.
func get_hint_text() -> String:
	return _hint_label.text


## Notice shown above the form.
func get_notice_text() -> String:
	return _notice_label.text


## Emits [signal realm_chosen] if everything is valid (what "Entrar" does). Returns true if it emitted it.
func try_enter() -> bool:
	if not _is_ready_to_enter():
		return false
	realm_chosen.emit(_selected_realm, _address_edit.text.strip_edges(),
			_name_edit.text.strip_edges())
	return true


# Fills in the fields and buttons with what setup() said.
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


# Fills in the count texts under the buttons: players, recommended and rejected.
func _refresh_counts() -> void:
	var recommended: int = get_recommended_realm()
	_counts_note.visible = has_realm_counts()
	_counts_note.text = TEXT_COUNTS_NOTE if has_realm_counts() else ""
	for realm: int in REALMS:
		var label: Label = _count_label(realm)
		var button: Button = get_realm_button(realm)
		button.tooltip_text = "" if is_realm_allowed(realm) else TEXT_NOT_ALLOWED
		if not has_realm_counts():
			# With no count, only the realm the server rejected is marked.
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


# Texts and state of "Entrar" according to what is typed and chosen.
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


# Reason why the typed address is not valid (empty if it is valid).
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
