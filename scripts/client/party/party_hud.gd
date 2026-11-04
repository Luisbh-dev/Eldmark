class_name PartyHud
extends VBoxContainer
## Party UI of the HUD (SOC-08, docs/social.md, section 12.5): on the left of the screen, the
## invitation prompt ([PartyInvitePrompt]) and below it the member frames ([PartyFrames]). It is mounted by the [HUD] online
## and fed by the [NetClient]'s [PartyState].
## [br][br]
## It also translates the chat box's party commands ([code]/invitar[/code], [code]/salir[/code],
## [code]/expulsar[/code], [code]/lider[/code]; invite, leave, kick, leader) into requests to the server ([method handle_command]); the server
## decides and answers through the system channel.
## [br][br]
## Client only.

## Column measurements (px of the base window).
const MARGIN_LEFT: float = 16.0
const MARGIN_TOP: float = 110.0
const WIDTH: float = PartyFrame.SIZE.x

var _client: NetClient = null
var _prompt: PartyInvitePrompt = null
var _frames: PartyFrames = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override(&"separation", 8)
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = MARGIN_LEFT
	offset_top = MARGIN_TOP
	offset_right = MARGIN_LEFT + WIDTH
	offset_bottom = MARGIN_TOP
	_prompt = PartyInvitePrompt.new()
	_prompt.name = "Invitacion"
	add_child(_prompt)
	_frames = PartyFrames.new()
	_frames.name = "Marcos"
	add_child(_frames)


## Connects the UI to the network client [param client] (its [PartyState], its position and the requests). With
## [param camera_rig], the invitation prompt's keys do not respond while another piece of the UI other than
## [param allowed_holder] holds the cursor ([method PartyInvitePrompt.bind]).
func bind(client: NetClient, camera_rig: CameraRig = null, allowed_holder: Object = null) -> void:
	_client = client
	var party: PartyState = client.get_party() if is_instance_valid(client) else null
	_prompt.bind(party, client, camera_rig, allowed_holder)
	_frames.bind(party, client)


func get_prompt() -> PartyInvitePrompt:
	return _prompt


func get_frames() -> PartyFrames:
	return _frames


## Handles a party command from the chat box ([constant ChatCommandParser.Kind.INVITE], [code]LEAVE[/code],
## [code]KICK[/code] or [code]LEADER[/code]). Returns false if it is not one of them or could not be sent.
func handle_command(command: ChatCommandParser.Command) -> bool:
	if not is_instance_valid(_client):
		return false
	match command.kind:
		ChatCommandParser.Kind.INVITE:
			return _client.send_party_invite(command.target)
		ChatCommandParser.Kind.LEAVE:
			return _client.send_party_leave()
		ChatCommandParser.Kind.KICK:
			return _client.send_party_kick(command.target)
		ChatCommandParser.Kind.LEADER:
			return _client.send_party_leader(command.target)
	return false
