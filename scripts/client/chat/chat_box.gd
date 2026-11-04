class_name ChatBox
extends Control
## HUD chat box (SOC-05, docs/social.md, sections 2, 4 and 12): the message log at the bottom
## left, with a tab per channel, and the line where text is typed.
## [br][br]
## [b]Opening and closing.[/b] Enter (action [code]chat_open[/code]) opens the line; typing
## [code]/[/code] opens it already with the slash. While it is open the cursor stays free (the
## camera does not turn and clicks are for the interface: [method CameraRig.set_ui_cursor_release])
## and the character neither moves nor uses buttons ([method LocalPlayerController.set_input_blocked]); this is what the interface windows do, and chat also
## freezes movement because typing is going on. Esc closes it without sending (handled in [method Node._input], before the camera sees it), Enter sends and closes, and a click outside the box
## (with any of the three mouse buttons) closes it without sending, to return to the game without
## looking for Esc. That click does not attack: [LocalPlayerController] suppresses the mouse
## buttons pressed with the cursor free until they are released. Switching system windows does not
## close it (on returning, typing continues). It only opens if no other window holds the cursor
## ([method CameraRig.is_ui_holding_cursor]).
## [br][br]
## [b]What is typed.[/b] [ChatCommandParser] decides whether it is text for the active channel (by
## default [constant ChatChannel.Id.SAY]) or a command in Spanish, case- and accent-insensitive:
## [code]/d[/code], [code]/z[/code], [code]/s nombre texto[/code], [code]/r[/code], [code]/g[/code],
## [code]/ayuda[/code] and the party ones, which are delivered to [member party_handler]. A channel
## command without text leaves that channel as the active one. Up and down arrows walk through the
## history of what was sent ([ChatInputHistory]). The text is sanitized ([ChatText]) before being
## sent, and the server sanitizes it again.
## [br][br]
## [b]What is shown.[/b] One tab per channel (all, say, zone, party, whispers and system), each
## line with its channel's color ([ChatStyle]) and the sender's name with its realm's color. The
## server's NOTICEs appear in the system channel. [b]Other players' text is painted as literal
## text[/b]: BBCode is never interpreted (it is added with [code]RichTextLabel.add_text[/code]).
## When closed, the box fades out [constant FADE_DELAY_SECONDS] s after the last message and
## reappears with the next one.
## [br][br]
## [b]Replying.[/b] [code]/r[/code] resolves the last whisper correspondent from what the client
## sees: from the copy of one's own whisper or from the received whisper ([method ChatLog.Line.whisper_partner]).
## [br][br]
## Sizes, colors and texts are provisional (pending the user). Client only.

## The line has been opened or closed.
signal opened
signal closed
## The player has typed a party command ([constant ChatCommandParser.Kind.INVITE],
## [code]LEAVE[/code], [code]KICK[/code] or [code]LEADER[/code]) and there is no [member party_handler]: another HUD piece (SOC-08) can listen to it.
signal party_command_requested(command: ChatCommandParser.Command)

## Tabs: name and the channels they show (empty list = all).
const TABS: Array[Dictionary] = [
	{"name": "Todo", "channels": []},
	{"name": "Decir", "channels": [ChatChannel.Id.SAY]},
	{"name": "Zona", "channels": [ChatChannel.Id.ZONE]},
	{"name": "Grupo", "channels": [ChatChannel.Id.PARTY]},
	{"name": "Susurros", "channels": [ChatChannel.Id.WHISPER]},
	{"name": "Sistema", "channels": [ChatChannel.Id.SYSTEM]},
]
## Sizes (base-window pixels) and margins.
const WIDTH: float = 560.0
const HEIGHT: float = 236.0
const MARGIN_LEFT: float = 16.0
const MARGIN_BOTTOM: float = 56.0
## Maximum characters of the line: the longest text the server accepts ([constant ChatText.MAX_CHARS]) behind the longest form of a command with name and text, [code]/susurrar [/code]
## (10 characters), with a name of [constant NameRules.MAX_LENGTH] letters and its space,
## and 4 of slack for extra spaces. If exceeded, it is not trimmed silently: a warning is shown
## ([method _on_line_text_rejected]).
const MAX_INPUT_CHARS: int = ChatText.MAX_CHARS + 10 + NameRules.MAX_LENGTH + 1 + 4
## Seconds without messages after which the closed box starts to fade, how long the fade lasts and
## resting opacity (0 = invisible).
const FADE_DELAY_SECONDS: float = 8.0
const FADE_SECONDS: float = 2.0
const IDLE_ALPHA: float = 0.0
## Unicode code of "/", to open the line with the slash on any keyboard layout.
const SLASH_UNICODE: int = 47
const TEXT_INPUT_HINT: String = "Escribe un mensaje o /ayuda"
const TEXT_NO_REPLY: String = "No tienes a quién responder."
const TEXT_WHISPER_USAGE: String = "Uso: /s nombre texto"
const TEXT_SEND_FAILED: String = "No se pudo enviar el mensaje."
const TEXT_NO_PARTIES: String = "Los grupos aún no están disponibles."

## Who handles the party commands: [code](command: ChatCommandParser.Command) -> void[/code].
## Without it, [signal party_command_requested] is emitted and, if nobody listens, a notice says they are unavailable.
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
# Seconds since the last activity (message, open or close); it starts already faded.
var _idle_seconds: float = FADE_DELAY_SECONDS + FADE_SECONDS
var _panel: PanelContainer = null
var _tabs: TabBar = null
var _label: RichTextLabel = null
var _input_row: HBoxContainer = null
var _prefix: Label = null
var _line: LineEdit = null
# Lines the RichTextLabel currently has (to remove the oldest ones when the cap is exceeded).
var _label_lines: int = 0
# A warning has already been shown that the line accepts no more characters (once each time it is opened).
var _rejected_warned: bool = false


func _ready() -> void:
	_ensure_built()
	_apply_visibility()


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	_release_input()
	_disconnect()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	# Esc closes the line before the camera sees it (which would use it to release the cursor).
	if event.is_action_pressed(&"ui_cancel"):
		close()
		if is_inside_tree():
			get_viewport().set_input_as_handled()
		return
	# A click outside the box closes it (the text field does not lose focus when clicking where
	# there is no control). The click goes on its way: if it lands on another window, it is for that
	# one; in the world it does not attack (see the header).
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click != null and click.pressed and is_outside_click(click):
		close()


## true if [param click], a click received in [method Node._input] (in viewport coordinates), is
## from the left, right or middle button and lands outside the box. The wheel does not count.
func is_outside_click(click: InputEventMouseButton) -> bool:
	if _panel == null or not _panel.is_inside_tree():
		return false
	if click.button_index != MOUSE_BUTTON_LEFT and click.button_index != MOUSE_BUTTON_RIGHT \
			and click.button_index != MOUSE_BUTTON_MIDDLE:
		return false
	var local: Vector2 = _panel.get_global_transform_with_canvas().affine_inverse() * click.position
	return not Rect2(Vector2.ZERO, _panel.size).has_point(local)


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



## Connects the box to the network client [param client] (the incoming messages and the NOTICEs;
## sending), the camera (which releases the cursor while typing) and the player controller (which
## suspends movement). It can be called before or after adding the box to the tree.
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


# --- Opening and closing ----------------------------------------------------------------------

## Opens the line with [param prefill] already typed (empty, or "/" when pressing the slash key).
## Returns false, without opening anything, if another window holds the cursor or there is no
## session. If it was already open, only the text changes.
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
	_rejected_warned = false
	_history.reset()
	_hold_input()
	_line.text = prefill
	_apply_visibility()
	if is_inside_tree():
		_line.grab_focus()
	_line.caret_column = _line.text.length()
	opened.emit()
	return true


## Closes the line without sending what was typed and returns the cursor and movement to the game.
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


# --- Input ------------------------------------------------------------------------------------

## Processes [param text] as if the player had typed it and pressed Enter: text for the active
## channel or a command. It does not close the line ([method _on_text_submitted] does).
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
		ChatCommandParser.Kind.SERVER:
			# The server handles it (docs/plataforma.md §9): the line goes through the GM channel and the
			# reply comes through the system channel.
			_send(ChatChannel.Id.GM, "", command.text)
		ChatCommandParser.Kind.UNKNOWN:
			add_system_text(ChatCommandParser.TEXT_UNKNOWN)
		ChatCommandParser.Kind.INVALID:
			add_system_text(command.error)


## Adds a server message to the log (what [signal NetClient.chat_received] does).
func add_message(message: NetMessages.ChatMessage) -> void:
	_ensure_built()
	var line: ChatLog.Line = _log.add_message(message, _own_name)
	var partner: String = line.whisper_partner()
	if not partner.is_empty():
		_reply_target = partner


## Adds a local text to the system channel (help, a command's errors, the server's NOTICEs).
func add_system_text(text: String) -> void:
	_ensure_built()
	_log.add_text(text, ChatChannel.Id.SYSTEM)


# --- State ------------------------------------------------------------------------------------

## The message log.
func get_log() -> ChatLog:
	return _log


func get_history() -> ChatInputHistory:
	return _history


## Channel that text without a command goes to.
func get_active_channel() -> int:
	return _active_channel


## Recipient of the active channel if it is a whisper (empty for the others).
func get_active_target() -> String:
	return _active_target


## Whom [code]/r[/code] replies to (empty = nobody yet).
func get_reply_target() -> String:
	return _reply_target


## Index of the open tab ([constant TABS]).
func get_tab() -> int:
	return _tab


## Opens tab [param index] ([constant TABS]) and repaints the log.
func set_tab(index: int) -> void:
	_ensure_built()
	index = clampi(index, 0, TABS.size() - 1)
	if _tabs.current_tab != index:
		_tabs.current_tab = index
	_select_tab(index)


## The plain text the log currently shows (for tests).
func get_visible_text() -> String:
	_ensure_built()
	return _label.get_parsed_text()


## Lines the log currently shows.
func get_visible_line_count() -> int:
	return _label_lines


## Opacity of the box right now (1 with the line open and just after a message).
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


## Advances the fade by [param delta] seconds (called by [method _process]).
func advance(delta: float) -> void:
	if not _open:
		_idle_seconds += delta
	_apply_visibility()


# --- Assembly ---------------------------------------------------------------------------------

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
	_line.text_change_rejected.connect(_on_line_text_rejected)
	_line.gui_input.connect(_on_line_gui_input)
	_line.focus_exited.connect(_on_line_focus_exited)
	_input_row.add_child(_line)
	_update_prefix()
	_apply_visibility()


# Tabs, text line and background depending on whether it is open or not, and the fade opacity.
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


# --- Log --------------------------------------------------------------------------------------

func _select_tab(index: int) -> void:
	_tab = index
	_rebuild()
	_idle_seconds = 0.0


# Repaints the whole log with the lines of the open tab.
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


# Adds a line at the end of the RichTextLabel, part by part and as literal text (never BBCode).
func _paint(line: ChatLog.Line) -> void:
	if _label_lines > 0:
		_label.newline()
	for part: Dictionary in ChatStyle.segments(line):
		_label.push_color(part["color"])
		_label.add_text(String(part["text"]))
		_label.pop()
	_label_lines += 1


# --- Server messages --------------------------------------------------------------------------

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


# --- Sending ----------------------------------------------------------------------------------

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


# Losing focus (another control takes it) closes the line, just like Esc. A click where there is
# no control does not remove focus: that case is handled by _input.
func _on_line_focus_exited() -> void:
	if _open:
		close()


# The line has reached MAX_INPUT_CHARS and lost part of what was typed or pasted: a warning is
# shown (once each time it is opened, so as not to fill the log key by key) instead of silently sending it trimmed.
func _on_line_text_rejected(_rejected: String) -> void:
	if _rejected_warned:
		return
	_rejected_warned = true
	add_system_text(ChatText.problem_text(ChatText.Problem.TOO_LONG))


# Sends [param text] through [param channel] (to [param target] if it is a whisper) after checking it.
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


# Changes the active channel (and its recipient, for a whisper).
func _set_active(channel: int, target: String) -> void:
	_active_channel = channel
	_active_target = target if channel == ChatChannel.Id.WHISPER else ""
	_update_prefix()


# /r: whisper to the last correspondent, or that whisper as the active channel if there is no text.
func _reply(text: String) -> void:
	if _reply_target.is_empty():
		add_system_text(TEXT_NO_REPLY)
		return
	if text.is_empty():
		_set_active(ChatChannel.Id.WHISPER, _reply_target)
	else:
		_send(ChatChannel.Id.WHISPER, _reply_target, text)


# Party commands: to whoever handles them (SOC-08) or, if there is nobody, a notice.
func _party(command: ChatCommandParser.Command) -> void:
	if party_handler.is_valid():
		party_handler.call(command)
		return
	if party_command_requested.get_connections().is_empty():
		add_system_text(TEXT_NO_PARTIES)
		return
	party_command_requested.emit(command)


# --- Cursor and movement ----------------------------------------------------------------------

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
