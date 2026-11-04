class_name SocialMenu
extends UIWindow
## Social menu over a player (SOC-07, docs/social.md, section 12.6): a small window with the name of the
## player the reticle points at and one button for each action that applies
## ([method SocialTarget.options_for]): invite to the party and whisper. With an enemy, a dead player or
## a fake player there is nothing to offer and the menu does not open ([method open_for] returns false).
## [br][br]
## It opens with the [code]social_menu[/code] key (picked up by the [HUD]). Like every [UIWindow], it
## frees the cursor while open, can be operated with the keyboard (the first button has focus; Enter
## presses it; arrows and Tab switch buttons) or with the mouse, and Esc closes it.
## [br][br]
## [b]Invite[/b] sends PARTY_INVITE ([method NetClient.send_party_invite]); [b]whisper[/b] closes the menu
## and opens the chat line with [code]/s name [/code] already typed ([method ChatBox.open]), ready for the
## text to be written. The server always decides and replies through the chat's system channel.
## [br][br]
## The second origin of social actions, a name clicked in the chat with the cursor free, is left for
## another phase (SOC-07 in the backlog).
## [br][br]
## Client only.

## An action has been chosen: [param option_id] is [constant SocialTarget.OPTION_INVITE] or
## [constant SocialTarget.OPTION_WHISPER] and [param target_name] is the player.
signal option_chosen(option_id: StringName, target_name: String)

const WINDOW_WIDTH: float = 260.0
const TITLE_FORMAT: String = "%s"

var _client: NetClient = null
var _chat: ChatBox = null
var _target_name: String = ""
var _buttons: Array[Button] = []


func _init() -> void:
	super()
	custom_minimum_size = Vector2(WINDOW_WIDTH, 0.0)
	get_content().add_theme_constant_override(&"separation", 6)


## Connects the menu with the network client [param client] (the player's realm, party and invitations),
## the chat box [param chat] (for whispering) and the camera [param camera_rig] (which frees the cursor
## while the menu is open).
func setup(client: NetClient, chat: ChatBox, camera_rig: CameraRig) -> void:
	_client = client
	_chat = chat
	bind_camera(camera_rig)


## Opens the menu over [param view], the player being pointed at. Returns false, opening nothing, if it
## does not support social actions ([method SocialTarget.is_social_target]: an enemy, a dead player or a
## fake player), there is no action to offer it or there is no session.
func open_for(view: RemotePlayerView) -> bool:
	if view == null or not is_instance_valid(_client) or _client.get_config() == null:
		return false
	var own_realm: int = _client.get_config().realm
	if not SocialTarget.is_social_target(view, own_realm):
		return false
	var options: Array[Dictionary] = SocialTarget.options_for(own_realm, view.get_realm(), view.get_net_id(),
			_client.get_party())
	if options.is_empty():
		return false
	_target_name = view.get_display_name()
	window_title = TITLE_FORMAT % _target_name
	_rebuild(options)
	open()
	return true


## The player the menu is open over.
func get_target_name() -> String:
	return _target_name


## The action buttons, in order.
func get_buttons() -> Array[Button]:
	return _buttons.duplicate()


## The button of action [param option_id], or null if the menu does not offer it.
func get_button(option_id: StringName) -> Button:
	for button: Button in _buttons:
		if StringName(button.get_meta(&"option", &"")) == option_id:
			return button
	return null


## Chooses action [param option_id] on the menu's player, as if its button were pressed.
func choose(option_id: StringName) -> void:
	var target: String = _target_name
	match option_id:
		SocialTarget.OPTION_INVITE:
			close()
			if is_instance_valid(_client):
				_client.send_party_invite(target)
		SocialTarget.OPTION_WHISPER:
			# The menu has the cursor: it closes before opening the chat line, which does not open with another window.
			close()
			if is_instance_valid(_chat):
				_chat.open("/s %s " % target)
		_:
			return
	option_chosen.emit(option_id, target)


func _rebuild(options: Array[Dictionary]) -> void:
	for button: Button in _buttons:
		get_content().remove_child(button)
		button.queue_free()
	_buttons.clear()
	for option: Dictionary in options:
		var button := Button.new()
		button.text = String(option["text"])
		button.set_meta(&"option", option["id"])
		button.focus_mode = Control.FOCUS_ALL
		var option_id: StringName = option["id"]
		button.pressed.connect(func() -> void: choose(option_id))
		get_content().add_child(button)
		_buttons.append(button)
	var as_controls: Array[Control] = []
	for button: Button in _buttons:
		as_controls.append(button)
	UIFocus.chain_vertical(as_controls)
