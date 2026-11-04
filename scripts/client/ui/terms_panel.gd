class_name TermsPanel
extends FrontScreen
## Accept new texts (docs/platform.md §4.2 and §13.2): when [code]GET /v1/account[/code] says
## [code]pending.terms_required[/code] (or [code]enter[/code] responds [code]terms_required[/code]), which
## texts have changed ([code]documents[/code]), each with its button to read it in the scrolling panel,
## and "Aceptar" (Accept) or "Cerrar sesión" (Log out). Until they are accepted, entering the world is not
## possible. Esc logs out. Client only.

## Pressed "Aceptar" (Accept).
signal accepted
## Pressed "Cerrar sesión" (Log out) or Esc.
signal logout_requested
## Asked to read text [param kind].
signal text_requested(kind: String)

const TEXT_INTRO: String = "Hemos cambiado estos textos. Léelos y acéptalos para seguir jugando:"

var _list: VBoxContainer = null
var _text_view: RichTextLabel = null
var _text_scroll: ScrollContainer = null
var _accept_button: Button = null
var _logout_button: Button = null
var _documents: PackedStringArray = PackedStringArray()


func _init() -> void:
	super()
	name = "TermsPanel"
	var column: VBoxContainer = _make_panel("Textos nuevos", 640.0)
	var intro := make_label(TEXT_INTRO)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(intro)
	_list = VBoxContainer.new()
	_list.name = "Documentos"
	column.add_child(_list)
	_text_scroll = ScrollContainer.new()
	_text_scroll.name = "Texto"
	_text_scroll.custom_minimum_size = Vector2(0.0, 260.0)
	_text_scroll.visible = false
	column.add_child(_text_scroll)
	_text_view = RichTextLabel.new()
	_text_view.fit_content = true
	_text_view.selection_enabled = true
	_text_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_scroll.add_child(_text_view)
	_logout_button = make_button("Cerrar sesión", 160.0, &"GhostButton")
	_accept_button = make_button("Aceptar", 200.0)
	_accept_button.name = "Aceptar"
	add_button_row(column, [_logout_button], [_accept_button])
	_busy_controls = [_accept_button, _logout_button]
	_accept_button.pressed.connect(func() -> void: accepted.emit())
	_logout_button.pressed.connect(func() -> void: logout_requested.emit())


func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree() and event.is_action_pressed(&"ui_cancel"):
		logout_requested.emit()
		get_viewport().set_input_as_handled()


## The texts that have changed ([code]terms[/code], [code]privacy[/code], [code]rules[/code]); empty = all three.
func set_documents(documents: PackedStringArray) -> void:
	_documents = documents if not documents.is_empty() else PackedStringArray(RegisterPanel.KINDS)
	for child: Node in _list.get_children():
		child.queue_free()
	for kind: String in _documents:
		var button := make_button("Leer %s" % RegisterPanel.KIND_TITLES.get(kind, kind), 0.0, &"GhostButton")
		button.name = "Leer_%s" % kind
		button.pressed.connect(func() -> void: text_requested.emit(kind))
		_list.add_child(button)
	_text_scroll.visible = false
	set_notice("")


func get_documents() -> PackedStringArray:
	return _documents


## Shows text [param kind] in the panel.
func show_text(_kind: String, text: String) -> void:
	_text_view.text = text
	_text_scroll.visible = true
	_text_scroll.scroll_vertical = 0


func get_accept_button() -> Button:
	return _accept_button


func get_logout_button() -> Button:
	return _logout_button
