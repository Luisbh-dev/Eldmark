class_name PartyInvitePrompt
extends PanelContainer
## Aviso de invitación a un grupo (SOC-08, docs/social.md, sección 12.5): «Ana te invita a su grupo», los
## segundos que quedan y las teclas para aceptar y rechazar (acciones [code]party_accept[/code] y
## [code]party_decline[/code], con el glifo de la tecla real). Se ve mientras [PartyState] tenga alguna
## invitación vigente, la más antigua primero; con más de una dice cuántas más hay.
## [br][br]
## Responder manda PARTY_RESPONSE ([method NetClient.send_party_response]); si sale, el cliente quita la
## invitación y el aviso desaparece al momento (el servidor confirma con su propio mensaje). Si no sale (la sesión
## se está cerrando), el aviso se queda como estaba.
## [br][br]
## Las teclas solo se atienden con el aviso a la vista, en [method Node._unhandled_input], y nunca mientras otra
## pieza de la interfaz tiene el cursor ([method CameraRig.is_ui_holding_cursor]: el menú social, el mapa, los
## ajustes, la línea del chat...), para que una Y o una N pulsadas en ella no respondan sin querer. La excepción
## es la pantalla de muerte (el [HUD] la da como [code]allowed_holder[/code] en [method bind]): no usa letras, y
## esperar a reaparecer es buen momento para aceptar. Los segundos salen del tick del servidor estimado por el
## cliente ([method NetClient.get_estimated_server_tick]).
## [br][br]
## Solo cliente.

const SECONDS_PER_TICK: float = 1.0 / 60.0
const TEXT_INVITES: String = "%s te invita a su grupo"
const TEXT_MORE: String = " (+%d más)"
const TEXT_SECONDS: String = "%d s"
const TEXT_ACCEPT: String = "Aceptar"
const TEXT_DECLINE: String = "Rechazar"

var _party: PartyState = null
var _client: NetClient = null
var _camera_rig: CameraRig = null
# Quien puede tener el cursor sin que se dejen de atender las teclas (la pantalla de muerte, a través del HUD).
var _allowed_holder: Object = null
var _title: Label = null
var _timer: Label = null
var _accept_glyph: UIKeyGlyph = null
var _decline_glyph: UIKeyGlyph = null


func _init() -> void:
	theme_type_variation = &"DebugPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 4)
	add_child(column)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override(&"separation", 10)
	column.add_child(top)
	_title = Label.new()
	_title.name = "Titulo"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	_timer = Label.new()
	_timer.name = "Segundos"
	_timer.theme_type_variation = &"DimLabel"
	top.add_child(_timer)
	var keys := HBoxContainer.new()
	keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	keys.add_theme_constant_override(&"separation", 8)
	column.add_child(keys)
	_accept_glyph = UIKeyGlyph.for_action(&"party_accept", true)
	keys.add_child(_accept_glyph)
	keys.add_child(_make_label(TEXT_ACCEPT))
	keys.add_child(_make_label("·"))
	_decline_glyph = UIKeyGlyph.for_action(&"party_decline", true)
	keys.add_child(_decline_glyph)
	keys.add_child(_make_label(TEXT_DECLINE))
	visible = false


func _ready() -> void:
	refresh()


func _process(_delta: float) -> void:
	refresh()


func _exit_tree() -> void:
	_disconnect()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _party == null:
		return
	if is_instance_valid(_camera_rig) and _camera_rig.is_ui_holding_cursor(_allowed_holder):
		return
	if event.is_action_pressed(&"party_accept"):
		respond(true)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"party_decline"):
		respond(false)
		get_viewport().set_input_as_handled()


## Conecta el aviso con el estado de grupo [param party] y el cliente [param client] (el tick del servidor y
## el envío de la respuesta). Con [param camera_rig], las teclas no responden mientras alguna pieza de la interfaz
## que no sea [param allowed_holder] tiene el cursor ([method CameraRig.is_ui_holding_cursor]).
func bind(party: PartyState, client: NetClient, camera_rig: CameraRig = null, allowed_holder: Object = null) -> void:
	_disconnect()
	_party = party
	_client = client
	_camera_rig = camera_rig
	_allowed_holder = allowed_holder
	if _party != null:
		_party.invitation_changed.connect(refresh)
	refresh()


## Responde a la invitación que se enseña: la acepta o la rechaza. Devuelve false si no hay ninguna o si la
## respuesta no ha salido, y entonces la invitación se queda; si sale, la quita
## [method NetClient.send_party_response].
func respond(accept: bool) -> bool:
	var invitation: PartyState.Invitation = _party.get_current_invitation() if _party != null else null
	if invitation == null or not is_instance_valid(_client):
		return false
	return _client.send_party_response(invitation.inviter, accept)


## Repinta el aviso (quita lo caducado, el texto y los segundos que quedan).
func refresh() -> void:
	if _party == null:
		visible = false
		return
	var server_tick: int = _client.get_estimated_server_tick() if is_instance_valid(_client) else 0
	if server_tick > 0:
		_party.prune_expired(server_tick)
	var invitation: PartyState.Invitation = _party.get_current_invitation()
	visible = invitation != null
	if invitation == null:
		return
	var text: String = TEXT_INVITES % invitation.inviter
	var more: int = _party.get_invitations().size() - 1
	if more > 0:
		text += TEXT_MORE % more
	_title.text = text
	_timer.text = TEXT_SECONDS % get_seconds_left()


## Segundos que le quedan a la invitación que se enseña (0 si no hay o ya caducó).
func get_seconds_left() -> int:
	var invitation: PartyState.Invitation = _party.get_current_invitation() if _party != null else null
	if invitation == null:
		return 0
	var server_tick: int = _client.get_estimated_server_tick() if is_instance_valid(_client) else 0
	return maxi(ceili(float(invitation.expire_tick - server_tick) * SECONDS_PER_TICK), 0)


func get_title_text() -> String:
	return _title.text


func get_timer_text() -> String:
	return _timer.text


func get_accept_glyph() -> UIKeyGlyph:
	return _accept_glyph


func get_decline_glyph() -> UIKeyGlyph:
	return _decline_glyph


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _disconnect() -> void:
	if _party != null and _party.invitation_changed.is_connected(refresh):
		_party.invitation_changed.disconnect(refresh)
