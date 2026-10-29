class_name ChatBox
extends Control
## Caja de chat del HUD (SOC-05, docs/social.md, secciones 2, 4 y 12): el registro de mensajes abajo a la
## izquierda, con pestañas por canal, y la línea donde se escribe.
## [br][br]
## [b]Abrir y cerrar.[/b] Intro (acción [code]chat_open[/code]) abre la línea; escribir [code]/[/code] la abre
## ya con la barra. Mientras está abierta el cursor queda libre (la cámara no gira y los clics son para la
## interfaz: [method CameraRig.set_ui_cursor_release]) y el personaje no se mueve ni usa botones
## ([method LocalPlayerController.set_input_blocked]); es lo que hacen las ventanas de la interfaz, y el chat
## además congela el movimiento porque se teclea. Esc la cierra sin enviar (se atiende en
## [method Node._input], antes de que lo vea la cámara) e Intro envía y cierra. Solo se abre si ninguna otra
## ventana tiene el cursor ([method CameraRig.is_ui_holding_cursor]).
## [br][br]
## [b]Qué se escribe.[/b] [ChatCommandParser] decide si es texto para el canal activo (por defecto
## [constant ChatChannel.Id.SAY]) o un comando en español sin distinguir mayúsculas ni tildes: [code]/d[/code],
## [code]/z[/code], [code]/s nombre texto[/code], [code]/r[/code], [code]/g[/code], [code]/ayuda[/code] y los
## de grupo, que se entregan a [member party_handler]. Un comando de canal sin texto deja ese canal como
## activo. Flecha arriba y abajo recorren el historial de lo enviado ([ChatInputHistory]). El texto se sanea
## ([ChatText]) antes de enviarse, y el servidor vuelve a sanearlo.
## [br][br]
## [b]Qué se ve.[/b] Una pestaña por canal (todo, decir, zona, grupo, susurros y sistema), cada línea con el color de
## su canal ([ChatStyle]) y el nombre del emisor con el de su reino. Los NOTICE del servidor salen en el
## canal del sistema. [b]El texto de otros jugadores se pinta como texto literal[/b]: nunca se interpreta
## BBCode (se añade con [code]RichTextLabel.add_text[/code]). Cerrada, la caja se desvanece
## [constant FADE_DELAY_SECONDS] s después del último mensaje y reaparece con el siguiente.
## [br][br]
## [b]Responder.[/b] [code]/r[/code] resuelve al último interlocutor de susurro con lo que ve el cliente: de la
## copia de un susurro propio o del susurro recibido ([method ChatLog.Line.whisper_partner]).
## [br][br]
## Medidas, colores y textos provisionales (pendiente del usuario). Solo cliente.

## La línea se ha abierto o cerrado.
signal opened
signal closed
## El jugador ha escrito un comando de grupo ([constant ChatCommandParser.Kind.INVITE], [code]LEAVE[/code],
## [code]KICK[/code] o [code]LEADER[/code]) y no hay [member party_handler]: otra pieza del HUD (SOC-08)
## puede escucharlo.
signal party_command_requested(command: ChatCommandParser.Command)

## Pestañas: nombre y canales que muestran (lista vacía = todos).
const TABS: Array[Dictionary] = [
	{"name": "Todo", "channels": []},
	{"name": "Decir", "channels": [ChatChannel.Id.SAY]},
	{"name": "Zona", "channels": [ChatChannel.Id.ZONE]},
	{"name": "Grupo", "channels": [ChatChannel.Id.PARTY]},
	{"name": "Susurros", "channels": [ChatChannel.Id.WHISPER]},
	{"name": "Sistema", "channels": [ChatChannel.Id.SYSTEM]},
]
## Medidas (píxeles de la ventana base) y márgenes.
const WIDTH: float = 560.0
const HEIGHT: float = 236.0
const MARGIN_LEFT: float = 16.0
const MARGIN_BOTTOM: float = 56.0
## Caracteres como mucho de la línea: el texto más una palabra de comando y un nombre.
const MAX_INPUT_CHARS: int = ChatText.MAX_CHARS + 2 + NameRules.MAX_LENGTH + 4
## Segundos sin mensajes tras los que la caja cerrada empieza a desvanecerse, lo que dura el fundido y
## opacidad en reposo (0 = invisible).
const FADE_DELAY_SECONDS: float = 8.0
const FADE_SECONDS: float = 2.0
const IDLE_ALPHA: float = 0.0
## Código Unicode de «/», para abrir la línea con la barra en cualquier distribución de teclado.
const SLASH_UNICODE: int = 47
const TEXT_INPUT_HINT: String = "Escribe un mensaje o /ayuda"
const TEXT_NO_REPLY: String = "No tienes a quién responder."
const TEXT_WHISPER_USAGE: String = "Uso: /s nombre texto"
const TEXT_SEND_FAILED: String = "No se pudo enviar el mensaje."
const TEXT_NO_PARTIES: String = "Los grupos aún no están disponibles."

## Quién atiende los comandos de grupo: [code](command: ChatCommandParser.Command) -> void[/code]. Sin él
## se emite [signal party_command_requested] y, si nadie lo escucha, se avisa de que no están disponibles.
var party_handler: Callable = Callable()

var _client: NetClient = null
var _camera_rig: CameraRig = null
var _controller: LocalPlayerController = null
var _log: ChatLog = ChatLog.new()
var _history: ChatInputHistory = ChatInputHistory.new()
var _open: bool = false
var _tab: int = 0
var _active_channel: int = ChatChannel.Id.SAY
var _active_target: String = ""
var _reply_target: String = ""
var _own_name: String = ""
# Segundos desde la última actividad (mensaje, apertura o cierre); empieza ya desvanecida.
var _idle_seconds: float = FADE_DELAY_SECONDS + FADE_SECONDS
var _panel: PanelContainer = null
var _tabs: TabBar = null
var _label: RichTextLabel = null
var _input_row: HBoxContainer = null
var _prefix: Label = null
var _line: LineEdit = null
# Líneas que tiene ahora el RichTextLabel (para quitar las más viejas al pasar del tope).
var _label_lines: int = 0


func _ready() -> void:
	_ensure_built()
	_apply_visibility()


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	_release_input()
	_disconnect()


func _input(event: InputEvent) -> void:
	# Esc cierra la línea antes de que lo vea la cámara (que lo usaría para soltar el cursor).
	if _open and event.is_action_pressed(&"ui_cancel"):
		close()
		if is_inside_tree():
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _open or not is_inside_tree():
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if event.is_action_pressed(&"chat_open"):
		if open():
			get_viewport().set_input_as_handled()
	elif key.unicode == SLASH_UNICODE:
		if open("/"):
			get_viewport().set_input_as_handled()



## Conecta la caja con el cliente de red [param client] (los mensajes que llegan y los NOTICE; el envío),
## la cámara (que libera el cursor mientras se escribe) y el controlador del jugador (que suspende el
## movimiento). Puede llamarse antes o después de añadir la caja al árbol.
func bind(client: NetClient, camera_rig: CameraRig, controller: LocalPlayerController) -> void:
	_release_input()
	_disconnect()
	_client = client
	_camera_rig = camera_rig
	_controller = controller
	_ensure_built()
	_own_name = ""
	if is_instance_valid(_client):
		var config: ClientConfig = _client.get_config()
		_own_name = config.display_name if config != null else ""
		_client.chat_received.connect(_on_chat_received)
		_client.notice_received.connect(_on_notice)
	if _open:
		_hold_input()


# --- Abrir y cerrar ---------------------------------------------------------------------------

## Abre la línea con [param prefill] ya escrito (vacío, o «/» al pulsar la barra). Devuelve false, sin abrir
## nada, si otra ventana tiene el cursor o no hay sesión. Si ya estaba abierta solo cambia el texto.
func open(prefill: String = "") -> bool:
	_ensure_built()
	if _open:
		_line.text = prefill
		_line.caret_column = _line.text.length()
		return true
	if is_instance_valid(_camera_rig) and _camera_rig.is_ui_holding_cursor():
		return false
	_open = true
	_idle_seconds = 0.0
	_history.reset()
	_hold_input()
	_line.text = prefill
	_apply_visibility()
	if is_inside_tree():
		_line.grab_focus()
	_line.caret_column = _line.text.length()
	opened.emit()
	return true


## Cierra la línea sin enviar lo escrito y devuelve el cursor y el movimiento al juego.
func close() -> void:
	if not _open:
		return
	_open = false
	_idle_seconds = 0.0
	_line.release_focus()
	_line.text = ""
	_history.reset()
	_release_input()
	_apply_visibility()
	closed.emit()


func is_open() -> bool:
	return _open


# --- Entrada ----------------------------------------------------------------------------------

## Procesa [param text] como si el jugador lo hubiera escrito y pulsado Intro: texto para el canal activo
## o un comando. No cierra la línea ([method _on_text_submitted] lo hace).
func submit(text: String) -> void:
	_ensure_built()
	var command: ChatCommandParser.Command = ChatCommandParser.parse(text)
	if command.kind != ChatCommandParser.Kind.EMPTY:
		_history.remember(text)
	match command.kind:
		ChatCommandParser.Kind.TEXT:
			_send(_active_channel, _active_target, command.text)
		ChatCommandParser.Kind.SEND:
			_send(command.channel, command.target, command.text)
		ChatCommandParser.Kind.SET_CHANNEL:
			_set_active(command.channel, command.target)
		ChatCommandParser.Kind.REPLY:
			_reply(command.text)
		ChatCommandParser.Kind.HELP:
			for line: String in ChatCommandParser.help_lines(command.topic):
				add_system_text(line)
		ChatCommandParser.Kind.INVITE, ChatCommandParser.Kind.LEAVE, ChatCommandParser.Kind.KICK, \
				ChatCommandParser.Kind.LEADER:
			_party(command)
		ChatCommandParser.Kind.UNKNOWN:
			add_system_text(ChatCommandParser.TEXT_UNKNOWN)
		ChatCommandParser.Kind.INVALID:
			add_system_text(command.error)


## Añade un mensaje del servidor al registro (lo que hace [signal NetClient.chat_received]).
func add_message(message: NetMessages.ChatMessage) -> void:
	_ensure_built()
	var line: ChatLog.Line = _log.add_message(message, _own_name)
	var partner: String = line.whisper_partner()
	if not partner.is_empty():
		_reply_target = partner


## Añade un texto local en el canal del sistema (ayuda, errores de un comando, NOTICE del servidor).
func add_system_text(text: String) -> void:
	_ensure_built()
	_log.add_text(text, ChatChannel.Id.SYSTEM)


# --- Estado -----------------------------------------------------------------------------------

## El registro de mensajes.
func get_log() -> ChatLog:
	return _log


func get_history() -> ChatInputHistory:
	return _history


## Canal al que va el texto sin comando.
func get_active_channel() -> int:
	return _active_channel


## Destinatario del canal activo si es un susurro (vacío en los demás).
func get_active_target() -> String:
	return _active_target


## A quién responde [code]/r[/code] (vacío = a nadie todavía).
func get_reply_target() -> String:
	return _reply_target


## Índice de la pestaña abierta ([constant TABS]).
func get_tab() -> int:
	return _tab


## Abre la pestaña [param index] ([constant TABS]) y repinta el registro.
func set_tab(index: int) -> void:
	_ensure_built()
	index = clampi(index, 0, TABS.size() - 1)
	if _tabs.current_tab != index:
		_tabs.current_tab = index
	_select_tab(index)


## El texto plano que muestra ahora el registro (para las pruebas).
func get_visible_text() -> String:
	_ensure_built()
	return _label.get_parsed_text()


## Líneas que muestra ahora el registro.
func get_visible_line_count() -> int:
	return _label_lines


## Opacidad de la caja ahora mismo (1 con la línea abierta y justo tras un mensaje).
func get_fade_alpha() -> float:
	if _open:
		return 1.0
	var faded: float = _idle_seconds - FADE_DELAY_SECONDS
	if faded <= 0.0:
		return 1.0
	return lerpf(1.0, IDLE_ALPHA, clampf(faded / FADE_SECONDS, 0.0, 1.0))


func get_label() -> RichTextLabel:
	_ensure_built()
	return _label


func get_input() -> LineEdit:
	_ensure_built()
	return _line


func get_tab_bar() -> TabBar:
	_ensure_built()
	return _tabs


func get_prefix_label() -> Label:
	_ensure_built()
	return _prefix


## Avanza el desvanecimiento [param delta] segundos (lo llama [method _process]).
func advance(delta: float) -> void:
	if not _open:
		_idle_seconds += delta
	_apply_visibility()


# --- Montaje ----------------------------------------------------------------------------------

func _ensure_built() -> void:
	if _panel != null:
		return
	_log.line_added.connect(_on_line_added)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = MARGIN_LEFT
	offset_right = MARGIN_LEFT + WIDTH
	offset_top = -(MARGIN_BOTTOM + HEIGHT)
	offset_bottom = -MARGIN_BOTTOM
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"DebugPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.name = "Columna"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 4)
	_panel.add_child(column)

	_tabs = TabBar.new()
	_tabs.name = "Pestanas"
	_tabs.focus_mode = Control.FOCUS_NONE
	for tab: Dictionary in TABS:
		_tabs.add_tab(String(tab["name"]))
	_tabs.tab_changed.connect(_select_tab)
	column.add_child(_tabs)

	_label = RichTextLabel.new()
	_label.name = "Registro"
	_label.bbcode_enabled = false
	_label.scroll_active = true
	_label.scroll_following = true
	_label.selection_enabled = false
	_label.focus_mode = Control.FOCUS_NONE
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_label.custom_minimum_size = Vector2(0.0, 80.0)
	column.add_child(_label)

	_input_row = HBoxContainer.new()
	_input_row.name = "Linea"
	_input_row.add_theme_constant_override(&"separation", 6)
	column.add_child(_input_row)
	_prefix = Label.new()
	_prefix.name = "Canal"
	_input_row.add_child(_prefix)
	_line = LineEdit.new()
	_line.name = "Texto"
	_line.max_length = MAX_INPUT_CHARS
	_line.placeholder_text = TEXT_INPUT_HINT
	_line.context_menu_enabled = false
	_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line.text_submitted.connect(_on_text_submitted)
	_line.gui_input.connect(_on_line_gui_input)
	_line.focus_exited.connect(_on_line_focus_exited)
	_input_row.add_child(_line)
	_update_prefix()
	_apply_visibility()


# Pestañas, línea de texto y fondo según esté abierta o no, y la opacidad del desvanecimiento.
func _apply_visibility() -> void:
	if _panel == null:
		return
	_tabs.visible = _open
	_input_row.visible = _open
	var alpha: float = get_fade_alpha()
	modulate.a = alpha
	visible = alpha > 0.01
	var filter: Control.MouseFilter = Control.MOUSE_FILTER_STOP if _open else Control.MOUSE_FILTER_IGNORE
	_panel.mouse_filter = filter
	_label.mouse_filter = Control.MOUSE_FILTER_PASS if _open else Control.MOUSE_FILTER_IGNORE


func _update_prefix() -> void:
	var text: String = ChatChannel.display_name(_active_channel)
	if _active_channel == ChatChannel.Id.WHISPER and not _active_target.is_empty():
		text = "Susurro a %s" % _active_target
	_prefix.text = text + ":"
	_prefix.add_theme_color_override(&"font_color", ChatStyle.channel_color(_active_channel))


# --- Registro ---------------------------------------------------------------------------------

func _select_tab(index: int) -> void:
	_tab = index
	_rebuild()
	_idle_seconds = 0.0


# Repinta el registro entero con las líneas de la pestaña abierta.
func _rebuild() -> void:
	_label.clear()
	_label_lines = 0
	var channels: Array[int] = []
	for channel: int in TABS[_tab]["channels"]:
		channels.append(channel)
	for line: ChatLog.Line in _log.get_filtered(channels):
		_paint(line)


func _on_line_added(line: ChatLog.Line) -> void:
	_idle_seconds = 0.0
	var channels: Array = TABS[_tab]["channels"]
	if channels.is_empty() or channels.has(line.channel):
		_paint(line)
		if _label_lines > ChatLog.MAX_LINES:
			_label.remove_paragraph(0)
			_label_lines -= 1
	_apply_visibility()


# Añade una línea al final del RichTextLabel, parte a parte y como texto literal (nunca BBCode).
func _paint(line: ChatLog.Line) -> void:
	if _label_lines > 0:
		_label.newline()
	for part: Dictionary in ChatStyle.segments(line):
		_label.push_color(part["color"])
		_label.add_text(String(part["text"]))
		_label.pop()
	_label_lines += 1


# --- Mensajes del servidor --------------------------------------------------------------------

func _on_chat_received(message: NetMessages.ChatMessage) -> void:
	add_message(message)


func _on_notice(_code: int, text: String) -> void:
	add_system_text(text)


func _disconnect() -> void:
	if is_instance_valid(_client):
		if _client.chat_received.is_connected(_on_chat_received):
			_client.chat_received.disconnect(_on_chat_received)
		if _client.notice_received.is_connected(_on_notice):
			_client.notice_received.disconnect(_on_notice)


# --- Envío ------------------------------------------------------------------------------------

func _on_text_submitted(text: String) -> void:
	submit(text)
	close()


func _on_line_gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed(&"ui_up"):
		_line.text = _history.previous(_line.text)
	elif event.is_action_pressed(&"ui_down"):
		_line.text = _history.next(_line.text)
	else:
		return
	_line.caret_column = _line.text.length()
	_line.accept_event()


# Perder el foco (un clic fuera, cambiar de ventana) cierra la línea, igual que Esc.
func _on_line_focus_exited() -> void:
	if _open:
		close()


# Envía [param text] por [param channel] (a [param target] si es un susurro) tras comprobarlo.
func _send(channel: int, target: String, text: String) -> void:
	if channel == ChatChannel.Id.WHISPER and ChatText.clean(target).is_empty():
		add_system_text(TEXT_WHISPER_USAGE)
		return
	var problem: int = ChatText.check(text)
	if problem == ChatText.Problem.EMPTY:
		return
	if problem != ChatText.Problem.OK:
		add_system_text(ChatText.problem_text(problem))
		return
	var cleaned: String = ChatText.sanitize(text)
	if not is_instance_valid(_client) or not _client.send_chat(channel, ChatText.clean(target), cleaned):
		add_system_text(TEXT_SEND_FAILED)


# Cambia el canal activo (y su destinatario, en un susurro).
func _set_active(channel: int, target: String) -> void:
	_active_channel = channel
	_active_target = target if channel == ChatChannel.Id.WHISPER else ""
	_update_prefix()


# /r: susurro al último interlocutor, o ese susurro como canal activo si no hay texto.
func _reply(text: String) -> void:
	if _reply_target.is_empty():
		add_system_text(TEXT_NO_REPLY)
		return
	if text.is_empty():
		_set_active(ChatChannel.Id.WHISPER, _reply_target)
	else:
		_send(ChatChannel.Id.WHISPER, _reply_target, text)


# Comandos de grupo: a quien los atienda (SOC-08) o, si no hay nadie, aviso.
func _party(command: ChatCommandParser.Command) -> void:
	if party_handler.is_valid():
		party_handler.call(command)
		return
	if party_command_requested.get_connections().is_empty():
		add_system_text(TEXT_NO_PARTIES)
		return
	party_command_requested.emit(command)


# --- Cursor y movimiento ----------------------------------------------------------------------

func _hold_input() -> void:
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)
	if is_instance_valid(_controller):
		_controller.set_input_blocked(true, self)


func _release_input() -> void:
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)
	if is_instance_valid(_controller):
		_controller.set_input_blocked(false, self)
