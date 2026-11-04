class_name PartyInvitePrompt
extends PanelContainer
## Party invitation prompt (SOC-08, docs/social.md, section 12.5): "Ana te invita a su grupo" (Ana invites you to her party), the
## seconds remaining and the keys to accept and decline ([code]party_accept[/code] and
## [code]party_decline[/code] actions, with the real key's glyph). It is visible while [PartyState] has any
## valid invitation, the oldest first; with more than one it says how many more there are.
## [br][br]
## Responding sends PARTY_RESPONSE ([method NetClient.send_party_response]); if it goes out, the client removes the
## invitation and the prompt disappears at once (the server confirms with its own message). If it does not go out (the session
## is closing), the prompt stays as it was.
## [br][br]
## The keys are only handled with the prompt in view, in [method Node._unhandled_input], and never while another
## piece of the UI holds the cursor ([method CameraRig.is_ui_holding_cursor]: the social menu, the map, the
## settings, the chat line...), so that a Y or an N pressed in it does not respond by accident. The exception
## is the death screen (the [HUD] gives it as [code]allowed_holder[/code] in [method bind]): it uses no letters, and
## waiting to respawn is a good time to accept. The seconds come from the server tick estimated by the
## client ([method NetClient.get_estimated_server_tick]).
## [br][br]
## Client only.

const SECONDS_PER_TICK: float = 1.0 / 60.0
const TEXT_INVITES: String = "%s te invita a su grupo"
const TEXT_MORE: String = " (+%d más)"
const TEXT_SECONDS: String = "%d s"
const TEXT_ACCEPT: String = "Aceptar"
const TEXT_DECLINE: String = "Rechazar"

var _party: PartyState = null
var _client: NetClient = null
var _camera_rig: CameraRig = null
# Who may hold the cursor without the keys ceasing to be handled (the death screen, via the HUD).
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


## Connects the prompt to the party state [param party] and the client [param client] (the server tick and
## sending the response). With [param camera_rig], the keys do not respond while any piece of the UI
## other than [param allowed_holder] holds the cursor ([method CameraRig.is_ui_holding_cursor]).
func bind(party: PartyState, client: NetClient, camera_rig: CameraRig = null, allowed_holder: Object = null) -> void:
	_disconnect()
	_party = party
	_client = client
	_camera_rig = camera_rig
	_allowed_holder = allowed_holder
	if _party != null:
		_party.invitation_changed.connect(refresh)
	refresh()


## Responds to the invitation being shown: accepts or declines it. Returns false if there is none or if the
## response did not go out, and then the invitation stays; if it goes out, it is removed by
## [method NetClient.send_party_response].
func respond(accept: bool) -> bool:
	var invitation: PartyState.Invitation = _party.get_current_invitation() if _party != null else null
	if invitation == null or not is_instance_valid(_client):
		return false
	return _client.send_party_response(invitation.inviter, accept)


## Redraws the prompt (removes what has expired, the text and the seconds remaining).
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


## Seconds left on the invitation being shown (0 if there is none or it has already expired).
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
