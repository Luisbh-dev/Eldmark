class_name SocialMenu
extends UIWindow
## Menú social sobre un jugador (SOC-07, docs/social.md, sección 12.6): una ventana pequeña con el nombre del
## jugador al que apunta la retícula y un botón por cada acción que aplica ([method SocialTarget.options_for]):
## invitar al grupo y susurrar. Con un enemigo no hay nada que ofrecer y el menú no se abre
## ([method open_for] devuelve false).
## [br][br]
## Se abre con la tecla [code]social_menu[/code] (la recoge el [HUD]). Como toda [UIWindow], libera el cursor
## mientras está abierta, se maneja con teclado (el primer botón tiene el foco; Intro lo pulsa; flechas y Tab
## cambian de botón) o con el ratón, y Esc la cierra.
## [br][br]
## [b]Invitar[/b] manda PARTY_INVITE ([method NetClient.send_party_invite]); [b]susurrar[/b] cierra el menú y abre la
## línea del chat con [code]/s nombre [/code] ya escrito ([method ChatBox.open]), listo para escribir el texto. El
## servidor decide siempre y contesta por el canal del sistema del chat.
## [br][br]
## El segundo origen de las acciones sociales, un nombre pulsado en el chat con el cursor libre, queda para otra
## fase (SOC-07 en el backlog).
## [br][br]
## Solo cliente.

## Se ha elegido una acción: [param option_id] es [constant SocialTarget.OPTION_INVITE] o
## [constant SocialTarget.OPTION_WHISPER] y [param target_name] el jugador.
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


## Conecta el menú con el cliente de red [param client] (el reino del jugador, su grupo y las invitaciones),
## la caja de chat [param chat] (para susurrar) y la cámara [param camera_rig] (que libera el cursor mientras el
## menú está abierto).
func setup(client: NetClient, chat: ChatBox, camera_rig: CameraRig) -> void:
	_client = client
	_chat = chat
	bind_camera(camera_rig)


## Abre el menú sobre [param view], el jugador al que se apunta. Devuelve false, sin abrir nada, si no hay
## ninguna acción que ofrecerle (un enemigo) o no hay sesión.
func open_for(view: RemotePlayerView) -> bool:
	if view == null or not is_instance_valid(_client) or _client.get_config() == null:
		return false
	var options: Array[Dictionary] = SocialTarget.options_for(_client.get_config().realm,
			view.get_realm(), view.get_net_id(), _client.get_party())
	if options.is_empty():
		return false
	_target_name = view.get_display_name()
	window_title = TITLE_FORMAT % _target_name
	_rebuild(options)
	open()
	return true


## El jugador sobre el que está abierto el menú.
func get_target_name() -> String:
	return _target_name


## Los botones de las acciones, en orden.
func get_buttons() -> Array[Button]:
	return _buttons.duplicate()


## El botón de la acción [param option_id], o null si el menú no la ofrece.
func get_button(option_id: StringName) -> Button:
	for button: Button in _buttons:
		if StringName(button.get_meta(&"option", &"")) == option_id:
			return button
	return null


## Elige la acción [param option_id] sobre el jugador del menú, como si se pulsara su botón.
func choose(option_id: StringName) -> void:
	var target: String = _target_name
	match option_id:
		SocialTarget.OPTION_INVITE:
			close()
			if is_instance_valid(_client):
				_client.send_party_invite(target)
		SocialTarget.OPTION_WHISPER:
			# El menú tiene el cursor: se cierra antes de abrir la línea, que no se abre con otra ventana.
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
