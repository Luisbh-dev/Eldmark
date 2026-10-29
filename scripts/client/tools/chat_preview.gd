class_name ChatPreview
extends Control
## Vista previa de la caja de chat (SOC-05; herramienta de desarrollo, solo cliente): la [ChatBox] sobre un
## fondo plano, con mensajes de ejemplo de todos los canales, y un cliente falso que devuelve como si fuera
## el servidor lo que se escribe, para probar a mano los comandos, las pestañas, el historial y el
## desvanecimiento sin lanzar un servidor.
## [br][br]
## Uso (necesita ventana: el renderizador de [code]--headless[/code] no dibuja nada):
## [codeblock]
## godot --path . res://scenes/tests/chat_preview.tscn -- [--shots=<carpeta>]
## xvfb-run -a godot --path . res://scenes/tests/chat_preview.tscn -- --shots=/ruta/absoluta/build/chat
## [/codeblock]
## Con [code]--shots=<carpeta>[/code] guarda tres capturas ([code]chat_closed.png[/code], con los mensajes
## en reposo; [code]chat_open.png[/code], con la línea abierta y un comando a medio escribir, y
## [code]chat_whispers.png[/code], con la pestaña de susurros), una hoja con la zona de la caja de las tres
## ([code]chat_demo.png[/code]) y cierra. Sin ella se queda abierta: Intro
## abre la línea, [code]/[/code] la abre con la barra, Esc la cierra, flecha arriba recorre el historial y
## [code]/ayuda[/code] lista los comandos.

## Nombre del jugador de la vista previa.
const OWN_NAME: String = "Ana"
## Color del fondo: un verde de prado apagado, como el mundo detrás del HUD.
const BACKGROUND_COLOR: Color = Color(0.2, 0.27, 0.24, 1.0)
## Fotogramas que se esperan antes de cada captura, para que el interfaz se dibuje.
const SETTLE_FRAMES: int = 6

var _chat: ChatBox = null
var _client: PreviewClient = null
var _shots_dir: String = ""
var _shots: Array[Image] = []


## Cliente falso: lo que se envía vuelve como un mensaje del servidor con el nombre del jugador, y un
## susurro además recibe una respuesta de su destinatario.
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


## La caja de chat de la vista previa.
func get_chat() -> ChatBox:
	return _chat


## El cliente falso.
func get_client() -> NetClient:
	return _client


# Una conversación de ejemplo que enseña todos los canales, el color del reino de cada nombre y que el
# BBCode de otro jugador se ve tal cual.
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


# Las tres capturas y cierre.
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


# Una hoja con la zona de la caja de cada captura, una al lado de otra.
func _save_sheet() -> void:
	if _shots.is_empty():
		return
	var first: Image = _shots[0]
	# Los controles están en coordenadas del lienzo base; la imagen, en las de la ventana.
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
