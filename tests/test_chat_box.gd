extends TestCase
## Tests of the HUD chat box ([ChatBox], SOC-05) with synthetic messages and a fake client: what
## is drawn (colors per channel, tabs, NOTICE in the system tab, other players' text without interpreting
## BBCode), the commands and the active channel, replying, the history with the up arrow, opening and closing with
## Enter, the bar, Esc and a click outside (the cursor and movement are suspended while typing), the line
## cap, the fade at rest and the mounting in the [HUD].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const OWN_NAME: String = "Ana"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"


## Network client that connects to nothing: it records what it is asked to send.
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


# --- Helpers --------------------------------------------------------------------------------

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


## A click of [param button] at [param at] (viewport coordinates) through the window's real input: press
## ([param press]) and release ([param release]).
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


# --- What is seen -----------------------------------------------------------------------------

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
	]), "each line with its format")
	assert_eq(_chat.get_visible_line_count(), 6, "six lines")
	# Each channel has its own color, and the system and the GMs are unmistakable.
	var seen: Dictionary = {}
	for channel: int in range(0, ChatChannel.MAX_ID + 1):
		var color: Color = ChatStyle.channel_color(channel)
		assert_false(seen.has(color), "channel %d has its own color" % channel)
		seen[color] = true
	# And the parts of a line carry the channel's color, with the name in that of its realm.
	var line: ChatLog.Line = _chat.get_log().get_lines()[1]
	var parts: Array[Dictionary] = ChatStyle.segments(line)
	assert_eq(parts.size(), 3, "label, name and text")
	assert_eq(parts[0]["color"], ChatStyle.channel_color(ChatChannel.Id.ZONE), "channel label")
	assert_eq(parts[2]["color"], ChatStyle.channel_color(ChatChannel.Id.ZONE), "channel text")
	assert_true(parts[1]["color"] != parts[2]["color"], "the name carries the realm's color")
	assert_eq(ChatStyle.line_text(line), "[Zona] Cora: Al fuerte", "the joined parts are the text")


func test_other_players_text_is_never_interpreted_as_bbcode() -> void:
	var hostile: String = "[b]negrita[/b] [color=red]rojo[/color] [url=http://x]enlace[/url] [img]res://icon.svg[/img]"
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Bruno", hostile))
	_chat.add_message(_message(ChatChannel.Id.ZONE, "[b]Falso[/b]", "[lb]nombre[rb]"))
	_chat.add_system_text("[font_size=80]NOTICE enorme[/font_size]")
	assert_false(_chat.get_label().bbcode_enabled, "the log does not interpret BBCode")
	var text: String = _chat.get_visible_text()
	assert_true(text.contains(hostile), "the text arrives as is, with its brackets")
	assert_true(text.contains("[Zona] [b]Falso[/b]: [lb]nombre[rb]"), "neither the name nor the escapes are interpreted")
	assert_true(text.contains("[font_size=80]NOTICE enorme[/font_size]"), "nor does the system")


func test_notices_from_the_server_show_in_the_system_channel() -> void:
	_client.notice_received.emit(NetProtocol.NoticeCode.INFO, "El fuerte ha sido capturado")
	_client.notice_received.emit(NetProtocol.NoticeCode.SHUTDOWN, "El servidor se está cerrando")
	var lines: Array[ChatLog.Line] = _chat.get_log().get_lines()
	assert_eq(lines.size(), 2, "two lines")
	assert_eq(lines[0].channel, ChatChannel.Id.SYSTEM, "in the system channel")
	assert_eq(lines[0].text, "El fuerte ha sido capturado", "text")
	_chat.set_tab(5)
	assert_eq(_chat.get_visible_text(), "El fuerte ha sido capturado\nEl servidor se está cerrando",
			"they are seen in the system tab")


func test_chat_from_the_client_signal_reaches_the_log() -> void:
	_client.chat_received.emit(_message(ChatChannel.Id.SAY, "Bruno", "Hola desde la red"))
	assert_eq(_chat.get_log().get_count(), 1, "one line")
	assert_eq(_chat.get_visible_text(), "Bruno dice: Hola desde la red", "drawn")


func test_tabs_filter_by_channel() -> void:
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "decir"))
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Cora", "zona"))
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Dani", "susurro", VARDHEIM, OWN_NAME))
	_chat.add_message(_message(ChatChannel.Id.PARTY, "Eva", "grupo"))
	_chat.add_system_text("sistema")
	var expected: Array[int] = [5, 1, 1, 1, 1, 1]
	assert_eq(_chat.get_tab_bar().tab_count, ChatBox.TABS.size(), "one tab per filter")
	for index: int in ChatBox.TABS.size():
		_chat.set_tab(index)
		assert_eq(_chat.get_tab(), index, "tab %d" % index)
		assert_eq(_chat.get_visible_line_count(), expected[index],
				"the tab \"%s\" shows %d" % [ChatBox.TABS[index]["name"], expected[index]])
	_chat.set_tab(4)
	assert_eq(_chat.get_visible_text(), "Dani te susurra: susurro", "whispers")
	# A new message only appears if the tab shows it.
	_chat.add_message(_message(ChatChannel.Id.ZONE, "Cora", "otra"))
	assert_eq(_chat.get_visible_line_count(), 1, "a zone one does not get into the whispers tab")
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Dani", "otro susurro", VARDHEIM, OWN_NAME))
	assert_eq(_chat.get_visible_line_count(), 2, "a whisper one does")
	_chat.set_tab(0)
	assert_eq(_chat.get_visible_line_count(), 7, "and everything is in \"Todo\" (All)")
	assert_eq(_chat.get_tab_bar().current_tab, 0, "the bar follows the tab")


func test_the_log_keeps_the_last_two_hundred_lines() -> void:
	for i: int in 250:
		_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "mensaje %d" % i))
	assert_eq(_chat.get_log().get_count(), ChatLog.MAX_LINES, "the log keeps 200")
	assert_eq(_chat.get_visible_line_count(), ChatLog.MAX_LINES, "and the box shows 200")
	var text: String = _chat.get_visible_text()
	assert_true(text.begins_with("Bruno dice: mensaje 50"), "the first 50 are gone")
	assert_true(text.ends_with("mensaje 249"), "and the last one is there")


# --- Commands ---------------------------------------------------------------------------------

func test_text_goes_to_the_active_channel_and_channel_commands_switch_it() -> void:
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.SAY, "by default it is said")
	_chat.submit("Hola a todos")
	_chat.submit("/z Hola zona")
	assert_eq(_client.sent.size(), 2, "two sends")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.SAY, "recipient": "", "text": "Hola a todos"},
			"say")
	assert_eq(_client.sent[1], {"channel": ChatChannel.Id.ZONE, "recipient": "", "text": "Hola zona"},
			"zone")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.SAY, "a command with text does not change the active channel")
	_client.sent.clear()

	_chat.submit("/g")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.PARTY, "/g leaves the party as the active one")
	assert_eq(_chat.get_prefix_label().text, "Grupo:", "and the line shows it")
	_chat.submit("Vamos")
	assert_eq(_client.sent[0]["channel"], ChatChannel.Id.PARTY, "text without a command goes to the party")
	_chat.submit("/d")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.SAY, "/d goes back to saying")
	assert_eq(_chat.get_prefix_label().text, "Decir:", "prefix")


func test_whisper_commands() -> void:
	_chat.submit("/s Bruno nos vemos")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.WHISPER, "recipient": "Bruno",
			"text": "nos vemos"}, "/s with name and text")
	_client.sent.clear()
	_chat.submit("/s Cora")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.WHISPER, "/s name leaves the whisper as the active one")
	assert_eq(_chat.get_active_target(), "Cora", "with its recipient")
	assert_eq(_chat.get_prefix_label().text, "Susurro a Cora:", "and the line shows it")
	_chat.submit("¿Vienes?")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.WHISPER, "recipient": "Cora",
			"text": "¿Vienes?"}, "text without a command goes to Cora")
	_chat.submit("/s")
	assert_eq(_chat.get_log().get_lines().back().text, "Uso: /s nombre [texto]", "without a name it explains the usage")


func test_reply_uses_the_last_whisper_partner_seen_by_the_client() -> void:
	_chat.submit("/r hola")
	assert_true(_client.sent.is_empty(), "with no conversation partner nothing is sent")
	assert_eq(_chat.get_log().get_lines().back().text, ChatBox.TEXT_NO_REPLY, "a notice is given")
	# Bruno whispers to me: I reply to him.
	_chat.add_message(_message(ChatChannel.Id.WHISPER, "Bruno", "¿Estás?", VARDHEIM, OWN_NAME))
	assert_eq(_chat.get_reply_target(), "Bruno", "the last one who whispered to me")
	_chat.submit("/r aquí estoy")
	assert_eq(_client.sent[0], {"channel": ChatChannel.Id.WHISPER, "recipient": "Bruno",
			"text": "aquí estoy"}, "/r replies to Bruno")
	# The copy of my own whisper to Cora is made by my conversation partner.
	_chat.add_message(_message(ChatChannel.Id.WHISPER, OWN_NAME, "Hola Cora", VARDHEIM, "Cora"))
	assert_eq(_chat.get_reply_target(), "Cora", "after whispering to Cora, replying is for Cora")
	_chat.submit("/responder")
	assert_eq(_chat.get_active_channel(), ChatChannel.Id.WHISPER, "/r without text leaves the whisper active")
	assert_eq(_chat.get_active_target(), "Cora", "to Cora")
	# Messages from other channels do not change the conversation partner.
	_chat.add_message(_message(ChatChannel.Id.SAY, "Dani", "hola"))
	assert_eq(_chat.get_reply_target(), "Cora", "saying does not change who to reply to")


func test_unknown_commands_and_help() -> void:
	_chat.submit("/xyz")
	assert_eq(_chat.get_log().get_lines().back().text, "Comando desconocido. Escribe /ayuda.", "unknown")
	assert_eq(_chat.get_log().get_lines().back().channel, ChatChannel.Id.SYSTEM, "in the system channel")
	assert_true(_client.sent.is_empty(), "none of that goes over the network")
	# /gm, /ignorar, /designorar and /reportar are handled by the server (docs/platform.md §9): they go through the GM channel and the
	# response arrives through the system one (for someone without the role, "Comando desconocido" (unknown command) all the same).
	_chat.submit("/GM hola")
	_chat.submit("/ignorar Bruno")
	assert_eq(_client.sent, [{"channel": ChatChannel.Id.GM, "recipient": "", "text": "gm hola"},
			{"channel": ChatChannel.Id.GM, "recipient": "", "text": "ignorar Bruno"}] as Array[Dictionary],
			"the server commands go out through the GM channel")
	_client.sent.clear()
	var before: int = _chat.get_log().get_count()
	_chat.submit("/AYUDA")
	assert_eq(_chat.get_log().get_count() - before, ChatCommandParser.COMMANDS.size() + 1,
			"/ayuda lists the commands")
	before = _chat.get_log().get_count()
	_chat.submit("/ayuda /Susurrar")
	assert_eq(_chat.get_log().get_count() - before, 2, "/ayuda command explains one")
	assert_true(_chat.get_log().get_lines()[before].text.begins_with("/s nombre"), "the command's usage")


func test_text_is_sanitized_and_checked_before_sending() -> void:
	_chat.submit("  [b]hola[/b]   mundo \n")
	assert_eq(_client.sent[0]["text"], "hola mundo", "what goes out is the sanitized text")
	_client.sent.clear()
	_chat.submit("[b][/b]")
	assert_true(_client.sent.is_empty(), "BBCode only: nothing to send")
	_chat.submit("x".repeat(300))
	assert_true(_client.sent.is_empty(), "300 characters are not sent")
	assert_eq(_chat.get_log().get_lines().back().text, ChatText.problem_text(ChatText.Problem.TOO_LONG),
			"a notice says it is too long")
	_client.accept_sends = false
	_chat.submit("hola")
	assert_eq(_chat.get_log().get_lines().back().text, ChatBox.TEXT_SEND_FAILED, "if the client does not send, a notice is given")


func test_party_commands_go_to_the_handler_or_say_they_are_not_available() -> void:
	_chat.submit("/invitar Bruno")
	assert_eq(_chat.get_log().get_lines().back().text, ChatBox.TEXT_NO_PARTIES, "with no one to handle them")
	var received: Array[ChatCommandParser.Command] = []
	_chat.party_handler = func(command: ChatCommandParser.Command) -> void: received.append(command)
	_chat.submit("/invitar Bruno")
	_chat.submit("/salir")
	assert_eq(received.size(), 2, "the handler receives both")
	assert_eq(received[0].kind, ChatCommandParser.Kind.INVITE, "invite")
	assert_eq(received[0].target, "Bruno", "Bruno")
	assert_eq(received[1].kind, ChatCommandParser.Kind.LEAVE, "leave")
	_chat.party_handler = Callable()
	var signalled: Array[ChatCommandParser.Command] = []
	_chat.party_command_requested.connect(func(command: ChatCommandParser.Command) -> void:
		signalled.append(command))
	_chat.submit("/expulsar Cora")
	assert_eq(signalled.size(), 1, "or it emits it as a signal")


# --- Open, close, history -----------------------------------------------------------------

func test_enter_opens_the_line_and_suspends_camera_and_movement() -> void:
	assert_false(_chat.is_open(), "starts closed")
	assert_false(_rig.is_cursor_free(), "the cursor belongs to the game")
	Input.action_press(&"move_forward")
	var free_input: PlayerInput = _controller.build_input(1)
	assert_true(free_input.move.y > 0.5, "without chat, the character advances (%s)" % free_input.move)

	_chat._unhandled_input(_key(KEY_ENTER))
	assert_true(_chat.is_open(), "Enter opens the line")
	assert_true(_chat.get_input().visible, "the line is visible")
	assert_true(_chat.get_tab_bar().visible, "and the tabs")
	assert_true(_rig.is_cursor_free(), "the cursor is left free: the camera does not turn")
	assert_true(_rig.is_ui_holding_cursor(), "because the interface has it")
	assert_true(_controller.is_input_blocked(), "and the game input, suspended")
	var blocked_input: PlayerInput = _controller.build_input(2)
	assert_eq(blocked_input.move, Vector2.ZERO, "the character does not move even if W is pressed")
	assert_eq(blocked_input.buttons, 0, "nor use buttons")

	# Esc closes without sending and gives everything back.
	_chat.get_input().text = "no se envía"
	_chat._input(_key(KEY_ESCAPE))
	assert_false(_chat.is_open(), "Esc closes it")
	assert_true(_client.sent.is_empty(), "without sending anything")
	assert_false(_rig.is_ui_holding_cursor(), "the cursor goes back to the game")
	assert_false(_controller.is_input_blocked(), "and the input too")
	var restored: PlayerInput = _controller.build_input(3)
	assert_true(restored.move.y > 0.5, "the character advances again")
	assert_eq(_chat.get_input().text, "", "the line is left empty")


func test_slash_opens_the_line_with_the_slash_in_any_keyboard_layout() -> void:
	# On a Spanish keyboard the slash is Shift+7: what matters is the character, not the key.
	_chat._unhandled_input(_key(KEY_7, 47))
	assert_true(_chat.is_open(), "the slash opens the line")
	assert_eq(_chat.get_input().text, "/", "already typed")
	assert_eq(_chat.get_input().caret_column, 1, "with the cursor after it")


func test_enter_submits_and_closes() -> void:
	_chat.open()
	_chat.get_input().text = "Hola desde la línea"
	_chat.get_input().text_submitted.emit(_chat.get_input().text)
	assert_eq(_client.sent[0]["text"], "Hola desde la línea", "it is sent")
	assert_false(_chat.is_open(), "and closes")
	assert_false(_rig.is_ui_holding_cursor(), "giving the cursor back")
	assert_eq(_chat.get_history().get_entries(), PackedStringArray(["Hola desde la línea"]), "it is remembered")


func test_the_line_does_not_open_while_another_window_holds_the_cursor() -> void:
	var other := Node.new()
	_track(other)
	_rig.set_ui_cursor_release(true, other)
	_chat._unhandled_input(_key(KEY_ENTER))
	assert_false(_chat.is_open(), "with a window open, Enter does not open the chat")
	assert_false(_chat.open(), "nor does open()")
	_rig.set_ui_cursor_release(false, other)
	_chat._unhandled_input(_key(KEY_ENTER))
	assert_true(_chat.is_open(), "once the window is closed, it does")


func test_a_click_outside_the_box_closes_the_line_without_attacking() -> void:
	# As in the HUD: the box in a canvas layer, the controller with the camera and the window's real input.
	_controller.setup(null, _rig)
	var layer := CanvasLayer.new()
	_track(layer)
	tree.root.remove_child(_chat)
	layer.add_child(_chat)
	await wait_process_frames()
	tree.root.push_input(_key(KEY_ENTER))
	if not assert_true(_chat.is_open(), "Enter opens the line"):
		return
	_chat.get_input().text = "a medio escribir"
	var blocked: PlayerInput = _controller.build_input(1)
	assert_eq(blocked.buttons, 0, "typing, no buttons")
	# A click on the log (inside the box) does not close it.
	_click(_chat.get_global_transform_with_canvas() * (_chat.size * 0.5))
	assert_true(_chat.is_open(), "a click inside the box does not close it")
	# The wheel outside neither.
	var outside: Vector2 = tree.root.get_visible_rect().size * Vector2(0.75, 0.2)
	assert_false(_chat.get_global_rect().has_point(outside), "the point is outside the box")
	_click(outside, MOUSE_BUTTON_WHEEL_UP)
	assert_true(_chat.is_open(), "the wheel does not close it")
	# A click in the world, outside the box: it closes without sending and everything goes back to the game.
	_click(outside, MOUSE_BUTTON_LEFT, true, false)
	assert_false(_chat.is_open(), "a click outside closes the line")
	assert_true(_client.sent.is_empty(), "without sending what was typed")
	assert_eq(_chat.get_input().text, "", "the line is left empty")
	assert_false(_rig.is_ui_holding_cursor(), "the cursor goes back to the game")
	assert_false(_controller.is_input_blocked(), "and the input too")
	# The button is still pressed, but that click does not attack: it was pressed with the cursor free.
	Input.action_press(&"primary_attack")
	var after_click: PlayerInput = _controller.build_input(2)
	assert_eq(after_click.buttons & PlayerInput.PRIMARY, 0, "the click that closes the chat does not attack")
	Input.action_release(&"primary_attack")
	_click(outside, MOUSE_BUTTON_LEFT, false, true)
	# Another frame: "just pressed" lasts the frame of the press.
	await wait_process_frames()
	assert_eq(_controller.build_input(3).buttons & PlayerInput.PRIMARY, 0, "released, nothing")
	Input.action_press(&"primary_attack")
	var next_click: PlayerInput = _controller.build_input(4)
	Input.action_release(&"primary_attack")
	assert_eq(next_click.buttons & PlayerInput.PRIMARY, PlayerInput.PRIMARY, "the next click, already in the game, does")


func test_the_line_fits_the_longest_whisper_and_warns_instead_of_cutting() -> void:
	var longest_name: String = "A" + "b".repeat(NameRules.MAX_LENGTH - 1)
	var longest_text: String = "x".repeat(ChatText.MAX_CHARS)
	# Any form of any command, with the longest name and text it admits, fits in the line.
	for spec: Dictionary in ChatCommandParser.COMMANDS:
		for alias: String in spec["names"]:
			var line: String = "/%s %s%s" % [alias, longest_name + " " if spec["id"] == &"whisper" else "",
					longest_text]
			assert_true(line.length() <= ChatBox.MAX_INPUT_CHARS, "\"/%s\" with the longest input fits (%d of %d)"
					% [alias, line.length(), ChatBox.MAX_INPUT_CHARS])
	# Pasting "/susurrar" with a 16-letter name and 255 characters: it arrives whole, without notices.
	_chat.open()
	var input: LineEdit = _chat.get_input()
	input.insert_text_at_caret("/susurrar %s %s" % [longest_name, longest_text])
	var command: ChatCommandParser.Command = ChatCommandParser.parse(input.text)
	assert_eq(command.target, longest_name, "the whole name")
	assert_eq(command.text.length(), ChatText.MAX_CHARS, "and the 255 characters, untrimmed")
	assert_eq(_chat.get_log().get_count(), 0, "without notices")
	# What no longer fits is not lost silently: a notice is given, only once while it stays open.
	input.insert_text_at_caret("y".repeat(10))
	assert_eq(input.text.length(), ChatBox.MAX_INPUT_CHARS, "the line stays at the cap")
	assert_eq(_chat.get_log().get_count(), 1, "one notice")
	assert_eq(_chat.get_log().get_lines().back().text, ChatText.problem_text(ChatText.Problem.TOO_LONG),
			"that it is too long")
	input.insert_text_at_caret("z")
	assert_eq(_chat.get_log().get_count(), 1, "one more key does not repeat the notice")
	_chat.close()
	_chat.open()
	input.insert_text_at_caret("w".repeat(ChatBox.MAX_INPUT_CHARS + 1))
	assert_eq(_chat.get_log().get_count(), 2, "on reopening it, the notice is given again")


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
	assert_eq(input.text, "tercero", "up arrow: the last one")
	input.gui_input.emit(up)
	assert_eq(input.text, "/z segundo", "again: the previous one")
	input.gui_input.emit(up)
	assert_eq(input.text, "primero", "and the first")
	input.gui_input.emit(up)
	assert_eq(input.text, "primero", "does not go past the oldest")
	input.gui_input.emit(down)
	assert_eq(input.text, "/z segundo", "down arrow: toward the newer ones")
	input.gui_input.emit(down)
	input.gui_input.emit(down)
	assert_eq(input.text, "borrador", "after the newest, what was being typed comes back")


func test_history_ignores_empty_and_repeated_lines() -> void:
	var history := ChatInputHistory.new()
	history.remember("uno")
	history.remember("uno")
	history.remember("   ")
	history.remember("dos")
	assert_eq(history.get_entries(), PackedStringArray(["uno", "dos"]), "no empty or consecutive repeated entries")
	assert_eq(history.previous("x"), "dos", "up")
	assert_eq(history.next("x"), "x", "down, to the draft")
	assert_eq(history.next("y"), "y", "without having gone up nothing changes")
	for i: int in 70:
		history.remember("línea %d" % i)
	assert_eq(history.get_entries().size(), ChatInputHistory.MAX_ENTRIES, "remembers 50")
	assert_eq(history.get_entries()[history.get_entries().size() - 1], "línea 69", "the newest ones")
	assert_eq(ChatInputHistory.new().previous("vacío"), "vacío", "without history nothing changes")


# --- Fading --------------------------------------------------------------------------

func test_the_box_fades_when_idle_and_returns_with_a_message() -> void:
	assert_false(_chat.visible, "with no messages there is nothing to see")
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "Hola"))
	assert_true(_chat.visible, "a message shows it")
	assert_eq(_chat.get_fade_alpha(), 1.0, "opaque")
	_chat.advance(ChatBox.FADE_DELAY_SECONDS - 0.5)
	assert_eq(_chat.get_fade_alpha(), 1.0, "before the delay it stays opaque")
	_chat.advance(0.5 + ChatBox.FADE_SECONDS * 0.5)
	assert_near(_chat.get_fade_alpha(), 0.5, 0.01, "halfway through the fade")
	assert_near(_chat.modulate.a, 0.5, 0.01, "and it shows in the opacity")
	_chat.advance(ChatBox.FADE_SECONDS)
	assert_eq(_chat.get_fade_alpha(), ChatBox.IDLE_ALPHA, "completely faded")
	assert_false(_chat.visible, "and hidden")
	_chat.add_message(_message(ChatChannel.Id.SAY, "Bruno", "Otra vez"))
	assert_eq(_chat.get_fade_alpha(), 1.0, "a new message brings it back")
	assert_true(_chat.visible, "visible")
	# With the line open it does not fade.
	_chat.advance(ChatBox.FADE_DELAY_SECONDS + ChatBox.FADE_SECONDS + 1.0)
	_chat.open()
	assert_eq(_chat.get_fade_alpha(), 1.0, "open, opaque")
	_chat.advance(100.0)
	assert_eq(_chat.get_fade_alpha(), 1.0, "and it does not fade while typing")
	_chat.close()
	assert_eq(_chat.get_fade_alpha(), 1.0, "on closing it starts counting from zero again")


# --- Preview -----------------------------------------------------------------------------

func test_the_preview_scene_builds_and_echoes_what_is_sent() -> void:
	var scene: PackedScene = load("res://scenes/tests/chat_preview.tscn") as PackedScene
	var preview: ChatPreview = _track(scene.instantiate()) as ChatPreview
	var chat: ChatBox = preview.get_chat()
	assert_eq(chat.get_log().get_count(), 9, "the sample messages")
	assert_true(chat.get_visible_text().contains("[b]negrita[/b]"), "the sample BBCode is shown literally")
	chat.submit("/s Dani hola desde la vista previa")
	await wait_process_frames(2)
	assert_eq(chat.get_log().get_count(), 11, "the fake client returns the whisper and the reply")
	assert_eq(chat.get_reply_target(), "Dani", "and /r replies to Dani")
	assert_eq(chat.get_log().get_lines().back().text, "Recibido, Ana.", "the reply")


# --- Mounting in the HUD ------------------------------------------------------------------------

func test_the_hud_mounts_the_chat_box_and_feeds_it() -> void:
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load("res://scenes/characters/player_character.tscn")
			as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	hud.bind(character, _rig)
	assert_null(hud.get_chat(), "the sandbox has no chat")
	hud.bind_net(_client, null)
	var chat: ChatBox = hud.get_chat()
	if not assert_not_null(chat, "online, it does"):
		return
	assert_true(chat.get_index() < hud.get_death_screen().get_index(), "below the death screen")
	_client.chat_received.emit(_message(ChatChannel.Id.ZONE, "Bruno", "Hola HUD"))
	assert_eq(chat.get_visible_text(), "[Zona] Bruno: Hola HUD", "the client's message reaches the box")
	# A second call rebuilds the box without duplicating it.
	hud.bind_net(_client, null)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is ChatBox).size(), 1,
			"a single box")
	_client.chat_received.emit(_message(ChatChannel.Id.SAY, "Cora", "Otra"))
	assert_eq(hud.get_chat().get_visible_line_count(), 1, "and each message is received only once")
