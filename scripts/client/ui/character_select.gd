class_name CharacterSelect
extends FrontScreen
## Character selection (UI-23, docs/platform.md §4.4 and §13.2): the list on the left (name in its
## realm's color, level and last zone; deleted ones in gray with their deadline to restore them), the 3D
## figure of the selected one ([CharacterFigure] with its appearance and its realm's colors) and the free
## slots ("Los borrados que aún puedes restaurar ocupan hueco" (Deleted characters you can still restore
## take up a slot)). Buttons: Enter, Create, Delete (confirmation by typing the name), Restore and Log
## out.
## [br][br]
## The data is that of [code]GET /v1/worlds/{w}/characters[/code] ([method set_data]). While waiting for
## the character to leave the world ([code]character_busy[/code], §5.3) the countdown is shown
## ([method show_waiting]). Keyboard: arrows choose, Enter enters and Del deletes. Client only.

## Pressed "Entrar" (Enter) (or Enter) with a living character selected.
signal enter_requested(character_id: int)
## Pressed "Crear" (Create).
signal create_requested
## Confirmed the deletion by typing the name: [param confirm_name] is what was typed.
signal delete_requested(character_id: int, confirm_name: String)
## Pressed "Restaurar" (Restore) on a deleted character.
signal restore_requested(character_id: int)
## Pressed "Cerrar sesión" (Log out).
signal logout_requested
## Pressed "Cancelar" (Cancel) while waiting for a character leaving the world.
signal wait_canceled

const TEXT_TITLE: String = "Tus personajes"
const TEXT_EMPTY: String = "Aún no tienes personajes en este mundo"
const TEXT_SLOTS: String = "Huecos libres: %d de %d"
const TEXT_SLOTS_NOTE: String = "Los borrados que aún puedes restaurar ocupan hueco"
const TEXT_LEVEL_ZONE: String = "Nivel %d · %s"
const TEXT_DELETED: String = "Borrado · se puede restaurar hasta el %s"
const TEXT_DELETE_TITLE: String = "Borrar personaje"
const TEXT_DELETE_HELP: String = "Escribe «%s» para borrarlo. Podrás restaurarlo durante 7 días."
const TEXT_WAITING: String = "Tu personaje está saliendo del mundo… (%d s)"
const TEXT_NO_ZONE: String = "Sin entrar aún"
const DELETED_MODULATE: Color = Color(0.6, 0.6, 0.6, 0.85)
## Name of each zone for the list.
const ZONE_NAMES: Dictionary = {"vado_gris": "Vado Gris", "test_world": "Mundo de pruebas"}

var _list: VBoxContainer = null
var _group: ButtonGroup = ButtonGroup.new()
var _entries: Array[Button] = []
var _empty_label: Label = null
var _slots_label: Label = null
var _figure: CharacterFigure = null
var _name_label: Label = null
var _detail_label: Label = null
var _enter_button: Button = null
var _create_button: Button = null
var _delete_button: Button = null
var _restore_button: Button = null
var _logout_button: Button = null
var _delete_box: Control = null
var _delete_help: Label = null
var _delete_edit: LineEdit = null
var _delete_confirm: Button = null
var _delete_cancel: Button = null
var _wait_box: Control = null
var _wait_label: Label = null
var _wait_cancel: Button = null
var _characters: Array[Dictionary] = []
var _slots: int = 0
var _used: int = 0
var _selected: int = -1
var _delete_target: int = -1


func _init() -> void:
	super()
	name = "CharacterSelect"
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 40)
	add_child(margin)
	var root := HBoxContainer.new()
	root.add_theme_constant_override(&"separation", 24)
	margin.add_child(root)

	var left_panel := PanelContainer.new()
	left_panel.theme_type_variation = &"WindowPanel"
	left_panel.custom_minimum_size = Vector2(420.0, 0.0)
	root.add_child(left_panel)
	var left := VBoxContainer.new()
	left.add_theme_constant_override(&"separation", ROW_SEPARATION)
	left_panel.add_child(left)
	left.add_child(make_label(TEXT_TITLE, &"HeaderLabel"))
	_notice_label = make_label("", &"ErrorLabel")
	_notice_label.name = "Aviso"
	_notice_label.visible = false
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_notice_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	_list = VBoxContainer.new()
	_list.name = "Lista"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override(&"separation", 6)
	scroll.add_child(_list)
	_empty_label = make_label(TEXT_EMPTY, &"DimLabel")
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_list.add_child(_empty_label)
	_slots_label = make_label("", &"DimLabel")
	_slots_label.name = "Huecos"
	left.add_child(_slots_label)
	var note := make_label(TEXT_SLOTS_NOTE, &"DimLabel")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(note)
	_create_button = make_button("Crear personaje", 0.0)
	_create_button.name = "Crear"
	left.add_child(_create_button)
	_logout_button = make_button("Cerrar sesión", 0.0, &"GhostButton")
	_logout_button.name = "CerrarSesion"
	left.add_child(_logout_button)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override(&"separation", ROW_SEPARATION)
	root.add_child(right)
	_figure = CharacterFigure.new()
	_figure.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_figure.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_figure)
	_name_label = make_label("", &"TitleLabel")
	_name_label.name = "Nombre"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(_name_label)
	_detail_label = make_label("", &"DimLabel")
	_detail_label.name = "Detalle"
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(_detail_label)
	_delete_button = make_button("Borrar", 140.0, &"DangerButton")
	_delete_button.name = "Borrar"
	_restore_button = make_button("Restaurar", 140.0)
	_restore_button.name = "Restaurar"
	_enter_button = make_button("Entrar", 220.0)
	_enter_button.name = "Entrar"
	add_button_row(right, [_delete_button, _restore_button], [_enter_button])

	_build_delete_box()
	_build_wait_box()
	_busy_controls = [_logout_button]
	_enter_button.pressed.connect(try_enter)
	_create_button.pressed.connect(func() -> void: create_requested.emit())
	_delete_button.pressed.connect(ask_delete)
	_restore_button.pressed.connect(try_restore)
	_logout_button.pressed.connect(func() -> void: logout_requested.emit())
	_refresh_state()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _busy or _delete_box.visible or _wait_box.visible:
		if _delete_box.visible and event.is_action_pressed(&"ui_cancel"):
			close_delete()
			get_viewport().set_input_as_handled()
		return
	var key: InputEventKey = event as InputEventKey
	if event.is_action_pressed(&"ui_down"):
		select_index(_next_index(1))
	elif event.is_action_pressed(&"ui_up"):
		select_index(_next_index(-1))
	elif event.is_action_pressed(&"ui_accept"):
		try_enter()
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_DELETE:
		ask_delete()
	else:
		return
	get_viewport().set_input_as_handled()


## The characters from [code]GET /v1/worlds/{w}/characters[/code] ([param data]:
## [code]{realm, unlock_at, slots, used, characters}[/code]). Keeps the selection if the character is still
## there (or selects [param select_id] if it is not 0); otherwise, the first living one.
func set_data(data: Dictionary, select_id: int = 0) -> void:
	var previous: int = get_selected_id()
	_characters.clear()
	var listed: Variant = data.get("characters", [])
	if listed is Array:
		for entry: Variant in listed:
			if entry is Dictionary and AccountFlow.parse_id((entry as Dictionary).get("character_id")) > 0:
				_characters.append(entry)
	_slots = _int(data.get("slots"), 0)
	_used = _int(data.get("used"), _characters.size())
	_rebuild_list()
	var wanted: int = select_id if select_id > 0 else previous
	var index: int = _index_of(wanted)
	if index < 0:
		index = _first_alive()
	if index < 0 and not _characters.is_empty():
		index = 0
	select_index(index)


## Selects character [param index] in the list (−1: none).
func select_index(index: int) -> void:
	_selected = index if index >= 0 and index < _characters.size() else -1
	for i: int in range(_entries.size()):
		_entries[i].set_pressed_no_signal(i == _selected)
	var character: Dictionary = get_selected_character()
	if character.is_empty():
		_name_label.text = ""
		_detail_label.text = ""
	else:
		_name_label.text = str(character.get("name", ""))
		_detail_label.text = entry_detail(character)
		var realm_code: int = RealmCatalog.code_of(StringName(str(character.get("realm", ""))))
		_name_label.add_theme_color_override(&"font_color",
				RealmCatalog.color_of(StringName(str(character.get("realm", "")))))
		_figure.show_appearance(AccountFlow.decode_base64(character.get("appearance")), realm_code)
	_refresh_state()


func get_selected_index() -> int:
	return _selected


## The selected character (empty if none).
func get_selected_character() -> Dictionary:
	return _characters[_selected] if _selected >= 0 and _selected < _characters.size() else {}


## The id of the selected character (0 if none).
func get_selected_id() -> int:
	return AccountFlow.parse_id(get_selected_character().get("character_id"))


## true if the selected one is deleted (within the window to restore it).
func is_selected_deleted() -> bool:
	var character: Dictionary = get_selected_character()
	return not character.is_empty() and character.get("deleted_at") != null


func get_character_count() -> int:
	return _characters.size()


## Free slots ([code]slots − used[/code]; deleted characters within the window take up slots).
func get_free_slots() -> int:
	return maxi(_slots - _used, 0)


## Emits [signal enter_requested] with the selected one if it is alive. Returns true if it emitted it.
func try_enter() -> bool:
	if _busy or get_selected_id() <= 0 or is_selected_deleted():
		return false
	enter_requested.emit(get_selected_id())
	return true


## Emits [signal restore_requested] with the selected one if it is deleted. Returns true if it emitted it.
func try_restore() -> bool:
	if _busy or get_selected_id() <= 0 or not is_selected_deleted():
		return false
	restore_requested.emit(get_selected_id())
	return true


## Opens the deletion confirmation for the selected (living) character: its name must be typed.
func ask_delete() -> void:
	if _busy or get_selected_id() <= 0 or is_selected_deleted():
		return
	_delete_target = get_selected_id()
	_delete_help.text = TEXT_DELETE_HELP % str(get_selected_character().get("name", ""))
	_delete_edit.text = ""
	_delete_box.visible = true
	_refresh_delete()
	if is_inside_tree():
		_delete_edit.grab_focus()


func close_delete() -> void:
	_delete_box.visible = false
	_delete_target = -1


func is_delete_open() -> bool:
	return _delete_box.visible


## Confirms the deletion if what was typed is the name (using [NameRules]'s key: case- and
## accent-insensitive, like the platform). Returns true if it emitted [signal delete_requested].
func confirm_delete() -> bool:
	if not _delete_box.visible or not _delete_matches():
		return false
	var target: int = _delete_target
	var typed: String = _delete_edit.text.strip_edges()
	close_delete()
	delete_requested.emit(target, typed)
	return true


## Shows the wait for a character leaving the world with [param seconds_left] s (−1 removes it).
func show_waiting(seconds_left: int) -> void:
	_wait_box.visible = seconds_left >= 0
	_wait_label.text = TEXT_WAITING % maxi(seconds_left, 0)


func is_waiting() -> bool:
	return _wait_box.visible


func get_waiting_text() -> String:
	return _wait_label.text if _wait_box.visible else ""


## The text of a character's second line: "Nivel 7 · Vado Gris" (Level 7 · Vado Gris) or the deletion one with
## its deadline.
static func entry_detail(character: Dictionary) -> String:
	if character.get("deleted_at") != null:
		var until: Variant = character.get("restore_until")
		return TEXT_DELETED % (PlatformErrors.format_date(int(until)) if until is float or until is int else "—")
	var zone: Variant = character.get("last_zone_id")
	var zone_text: String = TEXT_NO_ZONE
	if zone is String and not (zone as String).is_empty():
		zone_text = ZONE_NAMES.get(zone, (zone as String).capitalize())
	return TEXT_LEVEL_ZONE % [maxi(_int(character.get("level"), 1), 1), zone_text]


func get_entry_buttons() -> Array[Button]:
	return _entries


func get_figure() -> CharacterFigure:
	return _figure


func get_enter_button() -> Button:
	return _enter_button


func get_create_button() -> Button:
	return _create_button


func get_delete_button() -> Button:
	return _delete_button


func get_restore_button() -> Button:
	return _restore_button


func get_logout_button() -> Button:
	return _logout_button


func get_slots_text() -> String:
	return _slots_label.text


func get_delete_edit() -> LineEdit:
	return _delete_edit


func get_delete_confirm_button() -> Button:
	return _delete_confirm


func _refresh_state() -> void:
	super()
	if _enter_button == null:
		return
	var has_alive: bool = get_selected_id() > 0 and not is_selected_deleted()
	_enter_button.disabled = _busy or not has_alive
	_delete_button.disabled = _busy or not has_alive
	_delete_button.visible = not is_selected_deleted()
	_restore_button.visible = is_selected_deleted()
	_restore_button.disabled = _busy or not is_selected_deleted()
	_create_button.disabled = _busy or get_free_slots() <= 0
	_slots_label.text = TEXT_SLOTS % [get_free_slots(), _slots]
	for entry: Button in _entries:
		entry.disabled = _busy


func _rebuild_list() -> void:
	for entry: Button in _entries:
		entry.queue_free()
	_entries.clear()
	_empty_label.visible = _characters.is_empty()
	for i: int in range(_characters.size()):
		var character: Dictionary = _characters[i]
		var button := Button.new()
		button.name = "Personaje%d" % i
		button.toggle_mode = true
		button.button_group = _group
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0.0, 58.0)
		button.text = "%s\n%s" % [str(character.get("name", "")), entry_detail(character)]
		var realm_color: Color = RealmCatalog.color_of(StringName(str(character.get("realm", ""))))
		button.add_theme_color_override(&"font_color", realm_color)
		button.add_theme_color_override(&"font_pressed_color", realm_color.lightened(0.3))
		if character.get("deleted_at") != null:
			button.modulate = DELETED_MODULATE
		button.pressed.connect(select_index.bind(i))
		button.gui_input.connect(_on_entry_input.bind(i))
		_list.add_child(button)
		_entries.append(button)


func _build_delete_box() -> void:
	_delete_box = _make_overlay("BorrarConfirmacion")
	var column: VBoxContainer = _delete_box.get_meta(&"column")
	column.custom_minimum_size = Vector2(460.0, 0.0)
	column.add_child(make_label(TEXT_DELETE_TITLE, &"HeaderLabel"))
	_delete_help = make_label("", &"")
	_delete_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_delete_help)
	_delete_edit = make_line_edit("nombre del personaje", false, 32)
	_delete_edit.name = "Nombre"
	column.add_child(_delete_edit)
	_delete_cancel = make_button("Cancelar", 120.0, &"GhostButton")
	_delete_confirm = make_button("Borrar", 140.0, &"DangerButton")
	_delete_confirm.name = "ConfirmarBorrado"
	add_button_row(column, [_delete_cancel], [_delete_confirm])
	_delete_edit.text_changed.connect(func(_text: String) -> void: _refresh_delete())
	_delete_edit.text_submitted.connect(func(_text: String) -> void: confirm_delete())
	_delete_confirm.pressed.connect(confirm_delete)
	_delete_cancel.pressed.connect(close_delete)


func _build_wait_box() -> void:
	_wait_box = _make_overlay("Espera")
	var column: VBoxContainer = _wait_box.get_meta(&"column")
	_wait_label = make_label("", &"WarningLabel")
	column.add_child(_wait_label)
	_wait_cancel = make_button("Cancelar", 140.0, &"GhostButton")
	_wait_cancel.pressed.connect(func() -> void: wait_canceled.emit())
	column.add_child(_wait_cancel)


# A full-screen modal veil with a centered panel (hidden); its column goes in the "column" metadata.
func _make_overlay(overlay_name: String) -> Control:
	var overlay := Control.new()
	overlay.name = overlay_name
	overlay.visible = false
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	var dim := ColorRect.new()
	dim.color = UIPalette.MODAL_DIM
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"WindowPanel"
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", ROW_SEPARATION)
	panel.add_child(column)
	overlay.set_meta(&"column", column)
	return overlay


func _refresh_delete() -> void:
	_delete_confirm.disabled = not _delete_matches()


func _delete_matches() -> bool:
	var index: int = _index_of(_delete_target)
	if index < 0:
		return false
	var typed: String = _delete_edit.text.strip_edges()
	return not typed.is_empty() and NameRules.normalize_key(typed) \
			== NameRules.normalize_key(str(_characters[index].get("name", "")))


func _index_of(character_id: int) -> int:
	if character_id <= 0:
		return -1
	for i: int in range(_characters.size()):
		if AccountFlow.parse_id(_characters[i].get("character_id")) == character_id:
			return i
	return -1


func _first_alive() -> int:
	for i: int in range(_characters.size()):
		if _characters[i].get("deleted_at") == null:
			return i
	return -1


func _next_index(step: int) -> int:
	if _characters.is_empty():
		return -1
	if _selected < 0:
		return 0
	return clampi(_selected + step, 0, _characters.size() - 1)


# Double click on a living character: enter.
func _on_entry_input(event: InputEvent, index: int) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.pressed and button.double_click and button.button_index == MOUSE_BUTTON_LEFT:
		select_index(index)
		try_enter()


static func _int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float and is_finite(value) and value == floorf(value):
		return int(value)
	return fallback
