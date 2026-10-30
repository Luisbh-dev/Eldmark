extends TestCase
## Pruebas de la caja de chat del HUD ([ChatBox], SOC-05) con mensajes sintéticos y un cliente falso: lo que
## se pinta (colores por canal, pestañas, NOTICE en el sistema, el texto de otros jugadores sin interpretar
## BBCode), los comandos y el canal activo, responder, el historial con flecha arriba, abrir y cerrar con
## Intro, la barra, Esc y un clic fuera (el cursor y el movimiento se suspenden mientras se escribe), el tope de la
## línea, el desvanecimiento en reposo y el montaje en el [HUD].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const OWN_NAME: String = "Ana"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"


## Cliente de red que no conecta con nada: apunta lo que se le pide enviar.
class FakeClient extends NetClient:
	var sent: Array[Dictionary] = []
	var accept_sends: bool = true
	var fake_config: ClientConfig = ClientConfig.new()

	func send_chat(channel: int, recipient: String, text: String) -> bool:
		sent.append({"channel": channel, "recipient": recipient, "text": text})
		return accept_sends

	func get_config() -> ClientConfig:
		return fake_config


var _nodes: Array[Node] = []
var _client: FakeClient = null
var _chat: ChatBox = null
var _rig: CameraRig = null
var _controller: LocalPlayerController = null


func before_each() -> void:
	_nodes.clear()
	_client = _track(FakeClient.new()) as FakeClient
	_client.fake_config.display_name = OWN_NAME
	_client.fake_config.realm = VARDHEIM
	_controller = _track(LocalPlayerController.new()) as LocalPlayerController
	_rig = _track((load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate()) as CameraRig
	_chat = _track(ChatBox.new()) as ChatBox
	_chat.bind(_client, _rig, _controller)
	InputBindings.ensure_defaults()


func after_each() -> void:
	Input.action_release(&"move_forward")
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _track(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _message(channel: int, sender: String, text: String, realm: int = VARDHEIM,
		recipient: String = "") -> NetMessages.ChatMessage:
	var message := NetMessages.ChatMessage.new()
	message.channel = channel
	message.sender = sender
	message.sender_realm = realm
	message.recipient = recipient
	message.text = text
	message.tick = 100
	return message


## Un clic de [param button] en [param at] (coordenadas de la vista) por la entrada real de la ventana: pulsar
## ([param press]) y soltar ([param release]).
func _click(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, press: bool = true, release: bool = true) -> void:
	var window_position: Vector2 = tree.root.get_final_transform() * at
	for pressed: bool in [true, false]:
		if (pressed and not press) or (not pressed and not release):
			continue
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = window_position
		event.global_position = window_position
		tree.root.push_input(event)


func _key(keycode: Key, unicode: int = 0) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.unicode = unicode
	event.pressed = true
	return event


# --- Lo que se ve -----------------------------------------------------------------------------

func test_messages_are_painted_with_the_color_of_their_channel() -> void:
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "Hola"))
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Cora", "Al fuerte"))
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Dani", "Psst", VARDHEIM, OWN_NAME))
	_chat.add_message(_message(ChatChannel.Id.PARTY, "Eva", "Atacamos"))
	_chat.add_message(_message(ChatChannel.Id.SAY, OWN_NAME, "Hola yo"))
	_chat.add_system_text("Aviso del servidor")
	var text: String = _chat.get_visible_text()
	assert_eq(text.split("\n"), PackedStringArray([
		"Bruno dice: Hola",
		"[Zona] Cora: Al fuerte",
		"Dani te susurra: Psst",
		"[Grupo] Eva: Atacamos",
		"Dices: Hola yo",
		"Aviso del servidor",
	]), "cada línea con su formato")
	assert_eq(_chat.get_visible_line_count(), 6, "seis líneas")
	# Cada canal tiene un color propio, y el sistema y los GM, inconfundibles.
	var seen: Dictionary = {}
	for channel: int in range(0, ChatChannel.MAX_ID + 1):
		var color: Color = ChatStyle.channel_color(channel)
		assert_false(seen.has(color), "el canal %d tiene un color propio" % channel)
		seen[color] = true
	# Y las partes de una línea llevan el color del canal, con el nombre en el de su reino.
	var line: ChatLog.Line = _chat.get_log().get_lines()[1]
	var parts: Array[Dictionary] = ChatStyle.segments(line)
	assert_eq(parts.size(), 3, "etiqueta, nombre y texto")
	assert_eq(parts[0]["color"], ChatStyle.channel_color(ChatChannel.Id.ZONE), "etiqueta del canal")
	assert_eq(parts[2]["color"], ChatStyle.channel_color(ChatChannel.Id.ZONE), "texto del canal")
	assert_true(parts[1]["color"] != parts[2]["color"], "el nombre lleva el color del reino")
	assert_eq(ChatStyle.line_text(line), "[Zona] Cora: Al fuerte", "las partes unidas son el texto")


func test_other_players_text_is_never_interpreted_as_bbcode() -> void:
	var hostile: String = "[b]negrita[/b] [color=red]rojo[/color] [url=http://x]enlace[/url] [img]res://icon.svg[/img]"
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Bruno", hostile))
	_chat.add_message(_message(ChatChannel.Id.ZONE, "[b]Falso[/b]", "[lb]nombre[rb]"))
	_chat.add_system_text("[font_size=80]NOTICE enorme[/font_size]")
	assert_false(_chat.get_label().bbcode_enabled, "el registro no interpreta BBCode")
	var text: String = _chat.get_visible_text()
	assert_true(text.contains(hostile), "el texto llega tal cual, con sus corchetes")
	assert_true(text.contains("[Zona] [b]Falso[/b]: [lb]nombre[rb]"), "ni el nombre ni los escapes se interpretan")
	assert_true(text.contains("[font_size=80]NOTICE enorme[/font_size]"), "ni el sistema")


func test_notices_from_the_server_show_in_the_system_channel() -> void:
	_client.notice_received.emit(NetProtocol.NoticeCode.INFO, "El fuerte ha sido capturado")
	_client.notice_received.emit(NetProtocol.NoticeCode.SHUTDOWN, "El servidor se está cerrando")
	var lines: Array[ChatLog.Line] = _chat.get_log().get_lines()
	assert_eq(lines.size(), 2, "dos líneas")
	assert_eq(lines[0].channel, ChatChannel.Id.SYSTEM, "en el canal del sistema")
	assert_eq(lines[0].text, "El fuerte ha sido capturado", "texto")
	_chat.set_tab(5)
	assert_eq(_chat.get_visible_text(), "El fuerte ha sido capturado\nEl servidor se está cerrando",
			"se ven en la pestaña del sistema")


func test_chat_from_the_client_signal_reaches_the_log() -> void:
	_client.chat_received.emit(_message(ChatChannel.Id.SAY, "Bruno", "Hola desde la red"))
	assert_eq(_chat.get_log().get_count(), 1, "una línea")
	assert_eq(_chat.get_visible_text(), "Bruno dice: Hola desde la red", "pintada")


func test_tabs_filter_by_channel() -> void:
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "decir"))
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Cora", "zona"))
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Dani", "susurro", VARDHEIM, OWN_NAME))
	_chat.add_message(_message(ChatChannel.Id.PARTY, "Eva", "grupo"))
	_chat.add_system_text("sistema")
	var expected: Array[int] = [5, 1, 1, 1, 1, 1]
	assert_eq(_chat.get_tab_bar().tab_count, ChatBox.TABS.size(), "una pestaña por filtro")
	for index: int in ChatBox.TABS.size():
		_chat.set_tab(index)
		assert_eq(_chat.get_tab(), index, "pestaña %d" % index)
		assert_eq(_chat.get_visible_line_count(), expected[index],
				"la pestaña «%s» enseña %d" % [ChatBox.TABS[index]["name"], expected[index]])
	_chat.set_tab(4)
	assert_eq(_chat.get_visible_text(), "Dani te susurra: susurro", "susurros")
	# Un mensaje nuevo solo aparece si la pestaña lo muestra.
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Cora", "otra"))
	assert_eq(_chat.get_visible_line_count(), 1, "en la de susurros no entra uno de zona")
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Dani", "otro susurro", VARDHEIM, OWN_NAME))
	assert_eq(_chat.get_visible_line_count(), 2, "uno de susurro sí")
	_chat.set_tab(0)
	assert_eq(_chat.get_visible_line_count(), 7, "y todo está en «Todo»")
	assert_eq(_chat.get_tab_bar().current_tab, 0, "la barra sigue a la pestaña")


func test_the_log_keeps_the_last_two_hundred_lines() -> void:
	for i: int in 250:
		_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "mensaje %d" % i))
	assert_eq(_chat.get_log().get_count(), ChatLog.MAX_LINES, "el registro guarda 200")
	assert_eq(_chat.get_visible_line_count(), ChatLog.MAX_LINES, "y la caja enseña 200")
	var text: String = _chat.get_visible_text()
	assert_true(text.begins_with("Bruno dice: mensaje 50"), "las 50 primeras se han ido")
	assert_true(text.ends_with("mensaje 249"), "y la última está")


# --- Comandos ---------------------------------------------------------------------------------

func test_text_goes_to_the_active_channel_and_channel_commands_switch_it() -> void:
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.SAY, "por defecto se dice")
	_chat.submit("Hola a todos")
	_chat.submit("/z Hola zona")
	assert_eq(_client.sent.size(), 2, "dos envíos")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.SAY, "recipient": "", "text": "Hola a todos"},
			"decir")
	assert_eq(_client.sent[1], {"channel": ChatChannel.Id.ZONE, "recipient": "", "text": "Hola zona"},
			"zona")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.SAY, "un comando con texto no cambia el canal activo")
	_client.sent.clear()

	_chat.submit("/g")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.PARTY, "/g deja el grupo como activo")
	assert_eq(_chat.get_prefix_label().text, "Grupo:", "y la línea lo muestra")
	_chat.submit("Vamos")
	assert_eq(_client.sent[0]["channel"], ChatChannel.Id.PARTY, "el texto sin comando va al grupo")
	_chat.submit("/d")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.SAY, "/d vuelve a decir")
	assert_eq(_chat.get_prefix_label().text, "Decir:", "prefijo")


func test_whisper_commands() -> void:
	_chat.submit("/s Bruno nos vemos")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.WHISPER, "recipient": "Bruno",
			"text": "nos vemos"}, "/s con nombre y texto")
	_client.sent.clear()
	_chat.submit("/s Cora")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.WHISPER, "/s nombre deja el susurro como activo")
	assert_eq(_chat.get_active_target(), "Cora", "con su destinatario")
	assert_eq(_chat.get_prefix_label().text, "Susurro a Cora:", "y la línea lo muestra")
	_chat.submit("¿Vienes?")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.WHISPER, "recipient": "Cora",
			"text": "¿Vienes?"}, "el texto sin comando va a Cora")
	_chat.submit("/s")
	assert_eq(_chat.get_log().get_lines().back().text, "Uso: /s nombre [texto]", "sin nombre explica el uso")


func test_reply_uses_the_last_whisper_partner_seen_by_the_client() -> void:
	_chat.submit("/r hola")
	assert_true(_client.sent.is_empty(), "sin interlocutor no se envía")
	assert_eq(_chat.get_log().get_lines().back().text, ChatBox.TEXT_NO_REPLY, "se avisa")
	# Bruno me susurra: le contesto.
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Bruno", "¿Estás?", VARDHEIM, OWN_NAME))
	assert_eq(_chat.get_reply_target(), "Bruno", "el último que me susurró")
	_chat.submit("/r aquí estoy")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.WHISPER, "recipient": "Bruno",
			"text": "aquí estoy"}, "/r responde a Bruno")
	# La copia de mi propio susurro a Cora la hace mi interlocutora.
	_chat.add_message(_message(ChatChannel.Id.WHISPER, OWN_NAME, "Hola Cora", VARDHEIM, "Cora"))
	assert_eq(_chat.get_reply_target(), "Cora", "tras susurrar a Cora, responder es para Cora")
	_chat.submit("/responder")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.WHISPER, "/r sin texto deja el susurro activo")
	assert_eq(_chat.get_active_target(), "Cora", "a Cora")
	# Los mensajes de otros canales no cambian el interlocutor.
	_chat.add_message(_message(ChatChannel.Id.SAY, "Dani", "hola"))
	assert_eq(_chat.get_reply_target(), "Cora", "decir no cambia a quién responder")


func test_unknown_commands_and_help() -> void:
	_chat.submit("/xyz")
	assert_eq(_chat.get_log().get_lines().back().text, "Comando desconocido. Escribe /ayuda.", "desconocido")
	assert_eq(_chat.get_log().get_lines().back().channel, ChatChannel.Id.SYSTEM, "en el canal del sistema")
	assert_true(_client.sent.is_empty(), "nada de eso sale por la red")
	# /gm, /ignorar, /designorar y /reportar los atiende el servidor (docs/plataforma.md §9): van por el canal GM y la
	# respuesta llega por el del sistema (a quien no tiene rol, «Comando desconocido» igual).
	_chat.submit("/GM hola")
	_chat.submit("/ignorar Bruno")
	assert_eq(_client.sent, [{"channel": ChatChannel.Id.GM, "recipient": "", "text": "gm hola"},
			{"channel": ChatChannel.Id.GM, "recipient": "", "text": "ignorar Bruno"}] as Array[Dictionary],
			"los comandos del servidor salen por el canal GM")
	_client.sent.clear()
	var before: int = _chat.get_log().get_count()
	_chat.submit("/AYUDA")
	assert_eq(_chat.get_log().get_count() - before, ChatCommandParser.COMMANDS.size() + 1,
			"/ayuda lista los comandos")
	before = _chat.get_log().get_count()
	_chat.submit("/ayuda /Susurrar")
	assert_eq(_chat.get_log().get_count() - before, 2, "/ayuda comando explica uno")
	assert_true(_chat.get_log().get_lines()[before].text.begins_with("/s nombre"), "el uso del comando")


func test_text_is_sanitized_and_checked_before_sending() -> void:
	_chat.submit("  [b]hola[/b]   mundo \n")
	assert_eq(_client.sent[0]["text"], "hola mundo", "lo que sale es el texto saneado")
	_client.sent.clear()
	_chat.submit("[b][/b]")
	assert_true(_client.sent.is_empty(), "solo BBCode: nada que enviar")
	_chat.submit("x".repeat(300))
	assert_true(_client.sent.is_empty(), "300 caracteres no se envían")
	assert_eq(_chat.get_log().get_lines().back().text, ChatText.problem_text(ChatText.Problem.TOO_LONG),
			"se avisa de que es demasiado largo")
	_client.accept_sends = false
	_chat.submit("hola")
	assert_eq(_chat.get_log().get_lines().back().text, ChatBox.TEXT_SEND_FAILED, "si el cliente no envía, se avisa")


func test_party_commands_go_to_the_handler_or_say_they_are_not_available() -> void:
	_chat.submit("/invitar Bruno")
	assert_eq(_chat.get_log().get_lines().back().text, ChatBox.TEXT_NO_PARTIES, "sin nadie que los atienda")
	var received: Array[ChatCommandParser.Command] = []
	_chat.party_handler = func(command: ChatCommandParser.Command) -> void: received.append(command)
	_chat.submit("/invitar Bruno")
	_chat.submit("/salir")
	assert_eq(received.size(), 2, "el manejador recibe los dos")
	assert_eq(received[0].kind, ChatCommandParser.Kind.INVITE, "invitar")
	assert_eq(received[0].target, "Bruno", "a Bruno")
	assert_eq(received[1].kind, ChatCommandParser.Kind.LEAVE, "salir")
	_chat.party_handler = Callable()
	var signalled: Array[ChatCommandParser.Command] = []
	_chat.party_command_requested.connect(func(command: ChatCommandParser.Command) -> void:
		signalled.append(command))
	_chat.submit("/expulsar Cora")
	assert_eq(signalled.size(), 1, "o lo emite como señal")


# --- Abrir, cerrar, historial -----------------------------------------------------------------

func test_enter_opens_the_line_and_suspends_camera_and_movement() -> void:
	assert_false(_chat.is_open(), "empieza cerrada")
	assert_false(_rig.is_cursor_free(), "el cursor es del juego")
	Input.action_press(&"move_forward")
	var free_input: PlayerInput = _controller.build_input(1)
	assert_true(free_input.move.y > 0.5, "sin chat, el personaje avanza (%s)" % free_input.move)

	_chat._unhandled_input(_key(KEY_ENTER))
	assert_true(_chat.is_open(), "Intro abre la línea")
	assert_true(_chat.get_input().visible, "se ve la línea")
	assert_true(_chat.get_tab_bar().visible, "y las pestañas")
	assert_true(_rig.is_cursor_free(), "el cursor queda libre: la cámara no gira")
	assert_true(_rig.is_ui_holding_cursor(), "porque lo tiene la interfaz")
	assert_true(_controller.is_input_blocked(), "y la entrada de juego, suspendida")
	var blocked_input: PlayerInput = _controller.build_input(2)
	assert_eq(blocked_input.move, Vector2.ZERO, "el personaje no se mueve aunque se pulse W")
	assert_eq(blocked_input.buttons, 0, "ni usa botones")

	# Esc cierra sin enviar y lo devuelve todo.
	_chat.get_input().text = "no se envía"
	_chat._input(_key(KEY_ESCAPE))
	assert_false(_chat.is_open(), "Esc la cierra")
	assert_true(_client.sent.is_empty(), "sin enviar nada")
	assert_false(_rig.is_ui_holding_cursor(), "el cursor vuelve al juego")
	assert_false(_controller.is_input_blocked(), "y la entrada también")
	var restored: PlayerInput = _controller.build_input(3)
	assert_true(restored.move.y > 0.5, "el personaje vuelve a avanzar")
	assert_eq(_chat.get_input().text, "", "la línea queda vacía")


func test_slash_opens_the_line_with_the_slash_in_any_keyboard_layout() -> void:
	# En un teclado español la barra es Mayús+7: lo que importa es el carácter, no la tecla.
	_chat._unhandled_input(_key(KEY_7, 47))
	assert_true(_chat.is_open(), "la barra abre la línea")
	assert_eq(_chat.get_input().text, "/", "ya escrita")
	assert_eq(_chat.get_input().caret_column, 1, "con el cursor detrás")


func test_enter_submits_and_closes() -> void:
	_chat.open()
	_chat.get_input().text = "Hola desde la línea"
	_chat.get_input().text_submitted.emit(_chat.get_input().text)
	assert_eq(_client.sent[0]["text"], "Hola desde la línea", "se envía")
	assert_false(_chat.is_open(), "y se cierra")
	assert_false(_rig.is_ui_holding_cursor(), "devolviendo el cursor")
	assert_eq(_chat.get_history().get_entries(), PackedStringArray(["Hola desde la línea"]), "se recuerda")


func test_the_line_does_not_open_while_another_window_holds_the_cursor() -> void:
	var other := Node.new()
	_track(other)
	_rig.set_ui_cursor_release(true, other)
	_chat._unhandled_input(_key(KEY_ENTER))
	assert_false(_chat.is_open(), "con una ventana abierta, Intro no abre el chat")
	assert_false(_chat.open(), "ni open()")
	_rig.set_ui_cursor_release(false, other)
	_chat._unhandled_input(_key(KEY_ENTER))
	assert_true(_chat.is_open(), "cerrada la ventana, sí")


func test_a_click_outside_the_box_closes_the_line_without_attacking() -> void:
	# Como en el HUD: la caja en una capa de lienzo, el controlador con la cámara y la entrada real de la ventana.
	_controller.setup(null, _rig)
	var layer := CanvasLayer.new()
	_track(layer)
	tree.root.remove_child(_chat)
	layer.add_child(_chat)
	await wait_process_frames()
	tree.root.push_input(_key(KEY_ENTER))
	if not assert_true(_chat.is_open(), "Intro abre la línea"):
		return
	_chat.get_input().text = "a medio escribir"
	var blocked: PlayerInput = _controller.build_input(1)
	assert_eq(blocked.buttons, 0, "escribiendo, sin botones")
	# Un clic sobre el registro (dentro de la caja) no la cierra.
	_click(_chat.get_global_transform_with_canvas() * (_chat.size * 0.5))
	assert_true(_chat.is_open(), "un clic dentro de la caja no la cierra")
	# La rueda fuera tampoco.
	var outside: Vector2 = tree.root.get_visible_rect().size * Vector2(0.75, 0.2)
	assert_false(_chat.get_global_rect().has_point(outside), "el punto está fuera de la caja")
	_click(outside, MOUSE_BUTTON_WHEEL_UP)
	assert_true(_chat.is_open(), "la rueda no la cierra")
	# Un clic en el mundo, fuera de la caja: se cierra sin enviar y todo vuelve al juego.
	_click(outside, MOUSE_BUTTON_LEFT, true, false)
	assert_false(_chat.is_open(), "un clic fuera cierra la línea")
	assert_true(_client.sent.is_empty(), "sin enviar lo escrito")
	assert_eq(_chat.get_input().text, "", "la línea queda vacía")
	assert_false(_rig.is_ui_holding_cursor(), "el cursor vuelve al juego")
	assert_false(_controller.is_input_blocked(), "y la entrada también")
	# El botón sigue pulsado, pero ese clic no ataca: se pulsó con el cursor libre.
	Input.action_press(&"primary_attack")
	var after_click: PlayerInput = _controller.build_input(2)
	assert_eq(after_click.buttons & PlayerInput.PRIMARY, 0, "el clic que cierra el chat no ataca")
	Input.action_release(&"primary_attack")
	_click(outside, MOUSE_BUTTON_LEFT, false, true)
	# Otro fotograma: «recién pulsado» dura el fotograma de la pulsación.
	await wait_process_frames()
	assert_eq(_controller.build_input(3).buttons & PlayerInput.PRIMARY, 0, "soltado, nada")
	Input.action_press(&"primary_attack")
	var next_click: PlayerInput = _controller.build_input(4)
	Input.action_release(&"primary_attack")
	assert_eq(next_click.buttons & PlayerInput.PRIMARY, PlayerInput.PRIMARY, "el siguiente clic, ya en el juego, sí")


func test_the_line_fits_the_longest_whisper_and_warns_instead_of_cutting() -> void:
	var longest_name: String = "A" + "b".repeat(NameRules.MAX_LENGTH - 1)
	var longest_text: String = "x".repeat(ChatText.MAX_CHARS)
	# Cualquier forma de cualquier comando, con el nombre y el texto más largos que admite, cabe en la línea.
	for spec: Dictionary in ChatCommandParser.COMMANDS:
		for alias: String in spec["names"]:
			var line: String = "/%s %s%s" % [alias, longest_name + " " if spec["id"] == &"whisper" else "",
					longest_text]
			assert_true(line.length() <= ChatBox.MAX_INPUT_CHARS, "«/%s» con lo más largo cabe (%d de %d)"
					% [alias, line.length(), ChatBox.MAX_INPUT_CHARS])
	# Pegar «/susurrar» con un nombre de 16 letras y 255 caracteres: llega entero, sin avisos.
	_chat.open()
	var input: LineEdit = _chat.get_input()
	input.insert_text_at_caret("/susurrar %s %s" % [longest_name, longest_text])
	var command: ChatCommandParser.Command = ChatCommandParser.parse(input.text)
	assert_eq(command.target, longest_name, "el nombre entero")
	assert_eq(command.text.length(), ChatText.MAX_CHARS, "y los 255 caracteres, sin recortar")
	assert_eq(_chat.get_log().get_count(), 0, "sin avisos")
	# Lo que ya no cabe no se pierde en silencio: se avisa, una sola vez mientras sigue abierta.
	input.insert_text_at_caret("y".repeat(10))
	assert_eq(input.text.length(), ChatBox.MAX_INPUT_CHARS, "la línea se queda en el tope")
	assert_eq(_chat.get_log().get_count(), 1, "un aviso")
	assert_eq(_chat.get_log().get_lines().back().text, ChatText.problem_text(ChatText.Problem.TOO_LONG),
			"de que es demasiado largo")
	input.insert_text_at_caret("z")
	assert_eq(_chat.get_log().get_count(), 1, "una tecla más no repite el aviso")
	_chat.close()
	_chat.open()
	input.insert_text_at_caret("w".repeat(ChatBox.MAX_INPUT_CHARS + 1))
	assert_eq(_chat.get_log().get_count(), 2, "al volver a abrirla, se avisa otra vez")


func test_up_and_down_walk_the_history() -> void:
	for line: String in ["primero", "/z segundo", "tercero"]:
		_chat.submit(line)
	_chat.open()
	var input: LineEdit = _chat.get_input()
	input.text = "borrador"
	var up := InputEventKey.new()
	up.keycode = KEY_UP
	up.physical_keycode = KEY_UP
	up.pressed = true
	var down := InputEventKey.new()
	down.keycode = KEY_DOWN
	down.physical_keycode = KEY_DOWN
	down.pressed = true
	input.gui_input.emit(up)
	assert_eq(input.text, "tercero", "flecha arriba: la última")
	input.gui_input.emit(up)
	assert_eq(input.text, "/z segundo", "otra vez: la anterior")
	input.gui_input.emit(up)
	assert_eq(input.text, "primero", "y la primera")
	input.gui_input.emit(up)
	assert_eq(input.text, "primero", "no pasa de la más vieja")
	input.gui_input.emit(down)
	assert_eq(input.text, "/z segundo", "flecha abajo: hacia las nuevas")
	input.gui_input.emit(down)
	input.gui_input.emit(down)
	assert_eq(input.text, "borrador", "tras la más nueva vuelve lo que se estaba escribiendo")


func test_history_ignores_empty_and_repeated_lines() -> void:
	var history := ChatInputHistory.new()
	history.remember("uno")
	history.remember("uno")
	history.remember("   ")
	history.remember("dos")
	assert_eq(history.get_entries(), PackedStringArray(["uno", "dos"]), "sin vacíos ni repetidos seguidos")
	assert_eq(history.previous("x"), "dos", "arriba")
	assert_eq(history.next("x"), "x", "abajo, al borrador")
	assert_eq(history.next("y"), "y", "sin haber subido no cambia nada")
	for i: int in 70:
		history.remember("línea %d" % i)
	assert_eq(history.get_entries().size(), ChatInputHistory.MAX_ENTRIES, "recuerda 50")
	assert_eq(history.get_entries()[history.get_entries().size() - 1], "línea 69", "las más nuevas")
	assert_eq(ChatInputHistory.new().previous("vacío"), "vacío", "sin historial no cambia")


# --- Desvanecimiento --------------------------------------------------------------------------

func test_the_box_fades_when_idle_and_returns_with_a_message() -> void:
	assert_false(_chat.visible, "sin mensajes no hay nada que ver")
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "Hola"))
	assert_true(_chat.visible, "un mensaje la enseña")
	assert_eq(_chat.get_fade_alpha(), 1.0, "opaca")
	_chat.advance(ChatBox.FADE_DELAY_SECONDS - 0.5)
	assert_eq(_chat.get_fade_alpha(), 1.0, "antes del retardo sigue opaca")
	_chat.advance(0.5 + ChatBox.FADE_SECONDS * 0.5)
	assert_near(_chat.get_fade_alpha(), 0.5, 0.01, "a mitad del fundido")
	assert_near(_chat.modulate.a, 0.5, 0.01, "y se nota en la opacidad")
	_chat.advance(ChatBox.FADE_SECONDS)
	assert_eq(_chat.get_fade_alpha(), ChatBox.IDLE_ALPHA, "del todo desvanecida")
	assert_false(_chat.visible, "y oculta")
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "Otra vez"))
	assert_eq(_chat.get_fade_alpha(), 1.0, "un mensaje nuevo la devuelve")
	assert_true(_chat.visible, "visible")
	# Con la línea abierta no se desvanece.
	_chat.advance(ChatBox.FADE_DELAY_SECONDS + ChatBox.FADE_SECONDS + 1.0)
	_chat.open()
	assert_eq(_chat.get_fade_alpha(), 1.0, "abierta, opaca")
	_chat.advance(100.0)
	assert_eq(_chat.get_fade_alpha(), 1.0, "y no se desvanece escribiendo")
	_chat.close()
	assert_eq(_chat.get_fade_alpha(), 1.0, "al cerrar vuelve a contar desde cero")


# --- Vista previa -----------------------------------------------------------------------------

func test_the_preview_scene_builds_and_echoes_what_is_sent() -> void:
	var scene: PackedScene = load("res://scenes/tests/chat_preview.tscn") as PackedScene
	var preview: ChatPreview = _track(scene.instantiate()) as ChatPreview
	var chat: ChatBox = preview.get_chat()
	assert_eq(chat.get_log().get_count(), 9, "los mensajes de ejemplo")
	assert_true(chat.get_visible_text().contains("[b]negrita[/b]"), "el BBCode de ejemplo se ve literal")
	chat.submit("/s Dani hola desde la vista previa")
	await wait_process_frames(2)
	assert_eq(chat.get_log().get_count(), 11, "el cliente falso devuelve el susurro y la respuesta")
	assert_eq(chat.get_reply_target(), "Dani", "y /r responde a Dani")
	assert_eq(chat.get_log().get_lines().back().text, "Recibido, Ana.", "la respuesta")


# --- Montaje en el HUD ------------------------------------------------------------------------

func test_the_hud_mounts_the_chat_box_and_feeds_it() -> void:
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load("res://scenes/characters/player_character.tscn")
			as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	hud.bind(character, _rig)
	assert_null(hud.get_chat(), "el sandbox no tiene chat")
	hud.bind_net(_client, null)
	var chat: ChatBox = hud.get_chat()
	if not assert_not_null(chat, "en red, sí"):
		return
	assert_true(chat.get_index() < hud.get_death_screen().get_index(), "por debajo de la pantalla de muerte")
	_client.chat_received.emit(_message(ChatChannel.Id.ZONE, "Bruno", "Hola HUD"))
	assert_eq(chat.get_visible_text(), "[Zona] Bruno: Hola HUD", "el mensaje del cliente llega a la caja")
	# Una segunda llamada rehace la caja sin duplicarla.
	hud.bind_net(_client, null)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is ChatBox).size(), 1,
			"una sola caja")
	_client.chat_received.emit(_message(ChatChannel.Id.SAY, "Cora", "Otra"))
	assert_eq(hud.get_chat().get_visible_line_count(), 1, "y solo recibe cada mensaje una vez")
