class_name PartyHud
extends VBoxContainer
## Interfaz de grupo del HUD (SOC-08, docs/social.md, sección 12.5): a la izquierda de la pantalla, el aviso de
## invitación ([PartyInvitePrompt]) y debajo los marcos de los miembros ([PartyFrames]). La monta el [HUD] en red
## y la alimenta el [PartyState] del [NetClient].
## [br][br]
## También traduce los comandos de grupo de la caja de chat ([code]/invitar[/code], [code]/salir[/code],
## [code]/expulsar[/code], [code]/lider[/code]) en peticiones al servidor ([method handle_command]); el servidor
## decide y contesta por el canal del sistema.
## [br][br]
## Solo cliente.

## Medidas de la columna (px de la ventana base).
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


## Conecta la interfaz con el cliente de red [param client] (su [PartyState], su posición y las peticiones). Con
## [param camera_rig], las teclas del aviso de invitación no responden mientras otra pieza de la interfaz que no sea
## [param allowed_holder] tiene el cursor ([method PartyInvitePrompt.bind]).
func bind(client: NetClient, camera_rig: CameraRig = null, allowed_holder: Object = null) -> void:
	_client = client
	var party: PartyState = client.get_party() if is_instance_valid(client) else null
	_prompt.bind(party, client, camera_rig, allowed_holder)
	_frames.bind(party, client)


func get_prompt() -> PartyInvitePrompt:
	return _prompt


func get_frames() -> PartyFrames:
	return _frames


## Atiende un comando de grupo de la caja de chat ([constant ChatCommandParser.Kind.INVITE], [code]LEAVE[/code],
## [code]KICK[/code] o [code]LEADER[/code]). Devuelve false si no es uno de ellos o no se pudo enviar.
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
