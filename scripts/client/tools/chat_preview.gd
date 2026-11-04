class_name ChatPreview
extends Control
## Chat box preview (SOC-05; development tool, client only): the [ChatBox] over a flat background, with
## sample messages from all the channels, and a fake client that echoes back what is typed as if it were
## the server, to try out the commands, tabs, history and fade-out by hand without launching a server.
## [br][br]
## Usage (needs a window: the [code]--headless[/code] renderer draws nothing):
## [codeblock]
## godot --path . res://scenes/tests/chat_preview.tscn -- [--shots=<folder>]
## xvfb-run -a godot --path . res://scenes/tests/chat_preview.tscn -- --shots=/absolute/path/build/chat
## [/codeblock]
## With [code]--shots=<folder>[/code] it saves three screenshots ([code]chat_closed.png[/code], with the
## messages at rest; [code]chat_open.png[/code], with the line open and a command half typed; and
## [code]chat_whispers.png[/code], with the whispers tab), a sheet with the chat box area of the three
## ([code]chat_demo.png[/code]) and quits. Without it, it stays open: Enter opens the line, [code]/[/code]
## opens it with the slash, Esc closes it, up arrow walks through the history and
## [code]/ayuda[/code] lists the commands.

## Name of the preview player.
const OWN_NAME: String = "Ana"
## Background color: a muted meadow green, like the world behind the HUD.
const BACKGROUND_COLOR: Color = Color(0.2, 0.27, 0.24, 1.0)
## Frames to wait before each screenshot, so that the interface gets drawn.
const SETTLE_FRAMES: int = 6

var _chat: ChatBox = null
var _client: PreviewClient = null
var _shots_dir: String = ""
var _shots: Array[Image] = []


## Fake client: what is sent comes back as a server message with the player's name, and a whisper
## additionally gets a reply from its recipient.
class PreviewClient:
	extends NetClient

	var preview_config: ClientConfig = ClientConfig.new()

	func get_config() -> ClientConfig:
		return preview_config

	func send_chat(channel: int, recipient: String, text: String) -> bool:
		var cleaned: String = ChatText.sanitize(text)
		if cleaned.is_empty() or not ChatChannel.is_client_sendable(channel):
			return false
		var echo := NetMessages.ChatMessage.new()
		echo.channel = channel
		echo.sender = OWN_NAME
		echo.sender_realm = NetProtocol.Realm.VARDHEIM
		echo.recipient = recipient
		echo.text = cleaned
		chat_received.emit.call_deferred(echo)
		if channel == ChatChannel.Id.WHISPER:
			var answer := NetMessages.ChatMessage.new()
			answer.channel = ChatChannel.Id.WHISPER
			answer.sender = recipient
			answer.sender_realm = NetProtocol.Realm.VARDHEIM
			answer.recipient = OWN_NAME
			answer.text = "Recibido, %s." % OWN_NAME
			chat_received.emit.call_deferred(answer)
		return true


func _ready() -> void:
	InputBindings.ensure_defaults()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots_dir = arg.trim_prefix("--shots=")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.name = "Fondo"
	background.color = BACKGROUND_COLOR
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var help := Label.new()
	help.name = "Ayuda"
	help.text = "Vista previa del chat: Intro abre la línea · / la abre con la barra · Esc la cierra · " \
			+ "flecha arriba, historial · prueba /ayuda"
	help.position = Vector2(16.0, 16.0)
	add_child(help)

	_client = PreviewClient.new()
	_client.preview_config.display_name = OWN_NAME
	_client.preview_config.realm = NetProtocol.Realm.VARDHEIM
	add_child(_client)
	_chat = ChatBox.new()
	_chat.name = "Chat"
	add_child(_chat)
	_chat.bind(_client, null, null)
	_fill_sample_messages()
	if not _shots_dir.is_empty():
		_run_shots.call_deferred()


## The preview's chat box.
func get_chat() -> ChatBox:
	return _chat


## The fake client.
func get_client() -> NetClient:
	return _client


# A sample conversation showing all the channels, the realm color of each name and that another
# player's BBCode is shown as-is.
func _fill_sample_messages() -> void:
	var samples: Array[Dictionary] = [
		{"channel": ChatChannel.Id.SYSTEM, "sender": "", "text": "Bienvenida a Eldmark, %s." % OWN_NAME},
		{"channel": ChatChannel.Id.SAY, "sender": "Bruno", "text": "¿Alguien va hacia el fuerte?"},
		{"channel": ChatChannel.Id.SAY, "sender": OWN_NAME, "text": "Yo voy ahora mismo."},
		{"channel": ChatChannel.Id.ZONE, "sender": "Cora", "text": "Necesitamos gente en la puerta."},
		{"channel": ChatChannel.Id.PARTY, "sender": "Eva", "text": "Atacamos por el este en un minuto."},
		{"channel": ChatChannel.Id.WHISPER, "sender": "Dani", "recipient": OWN_NAME,
				"text": "¿Tienes un momento?"},
		{"channel": ChatChannel.Id.WHISPER, "sender": OWN_NAME, "recipient": "Dani", "text": "Claro, dime."},
		{"channel": ChatChannel.Id.SAY, "sender": "Bruno",
				"text": "[b]negrita[/b] y [color=red]rojo[/color] se ven tal cual"},
		{"channel": ChatChannel.Id.SYSTEM, "sender": "", "text": "Hablas demasiado rápido."},
	]
	for sample: Dictionary in samples:
		var message := NetMessages.ChatMessage.new()
		message.channel = sample["channel"]
		message.sender = sample["sender"]
		message.recipient = sample.get("recipient", "")
		message.text = sample["text"]
		message.sender_realm = NetProtocol.Realm.NONE if message.channel == ChatChannel.Id.SYSTEM \
				else NetProtocol.Realm.VARDHEIM
		_chat.add_message(message)


# The three screenshots and quit.
func _run_shots() -> void:
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	await _settle()
	await _capture("chat_closed.png")
	_chat.open("/s Dani ")
	await _settle()
	await _capture("chat_open.png")
	_chat.set_tab(4)
	await _settle()
	await _capture("chat_whispers.png")
	_save_sheet()
	print("[ChatPreview] Capturas en %s" % _shots_dir)
	get_tree().quit()


func _settle() -> void:
	for _i: int in SETTLE_FRAMES:
		await get_tree().process_frame


func _capture(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		push_warning("[ChatPreview] Sin imagen: ¿se lanzó con --headless? Hace falta una ventana (xvfb-run).")
		return
	_shots.append(image)
	var path: String = _shots_dir.path_join(file_name)
	var error: Error = image.save_png(path)
	if error != OK:
		push_warning("[ChatPreview] No se pudo guardar %s (%s)" % [path, error_string(error)])


# A sheet with each screenshot's chat box area, side by side.
func _save_sheet() -> void:
	if _shots.is_empty():
		return
	var first: Image = _shots[0]
	# The controls are in base canvas coordinates; the image, in window coordinates.
	var scale_factor: Vector2 = Vector2(first.get_size()) / get_viewport().get_visible_rect().size
	var area: Rect2 = _chat.get_global_rect().grow(8.0)
	var region := Rect2i(Vector2i(area.position * scale_factor), Vector2i(area.size * scale_factor))
	region = region.intersection(Rect2i(Vector2i.ZERO, first.get_size()))
	var gap: int = 10
	var sheet: Image = Image.create_empty(region.size.x * _shots.size() + gap * (_shots.size() - 1),
			region.size.y, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.12, 0.12, 0.12))
	for i: int in _shots.size():
		var piece: Image = _shots[i].get_region(region)
		piece.convert(Image.FORMAT_RGB8)
		sheet.blit_rect(piece, Rect2i(Vector2i.ZERO, region.size), Vector2i(i * (region.size.x + gap), 0))
	sheet.save_png(_shots_dir.path_join("chat_demo.png"))
