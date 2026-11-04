extends TestCase
## Tests for the interface components that do not draw a slot (UI-09): the key glyph
## ([UIKeyGlyph]) and the hint line ([UIHintBar]), the sound hooks ([UISounds]) and the
## focus neighbors ([UIFocus]).

const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const TEST_ACTION: StringName = &"ui_test_glyph"

var _nodes: Array[Node] = []
var _director: AudioDirector = null


func before_each() -> void:
	InputBindings.ensure_defaults()
	UISounds.reset()
	_erase_test_action()


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	_director = null
	UISounds.reset()
	_erase_test_action()
	AudioBuses.reset_volumes()


func _add(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _erase_test_action() -> void:
	if InputMap.has_action(TEST_ACTION):
		InputMap.erase_action(TEST_ACTION)


func _key(physical: Key, ctrl: bool = false, shift: bool = false) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = physical
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	return event


func _mouse(button: MouseButton) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	return event


func _bind(events: Array[InputEvent]) -> void:
	_erase_test_action()
	InputMap.add_action(TEST_ACTION)
	for event: InputEvent in events:
		InputMap.action_add_event(TEST_ACTION, event)


# --- Key glyph --------------------------------------------------------------------------------

func test_default_actions_show_their_real_keys() -> void:
	assert_eq(UIKeyGlyph.label_for_action(&"move_forward"), "W")
	assert_eq(UIKeyGlyph.label_for_action(&"move_left"), "A")
	assert_eq(UIKeyGlyph.label_for_action(&"jump"), "Espacio")
	assert_eq(UIKeyGlyph.label_for_action(&"sprint"), "Mayús")
	assert_eq(UIKeyGlyph.label_for_action(&"dodge"), "Ctrl")
	assert_eq(UIKeyGlyph.label_for_action(&"primary_attack"), "Clic izq.")
	assert_eq(UIKeyGlyph.label_for_action(&"block"), "Clic der.")
	assert_eq(UIKeyGlyph.label_for_action(&"ability_1"), "1")
	assert_eq(UIKeyGlyph.label_for_action(&"interact"), "E")
	assert_eq(UIKeyGlyph.label_for_action(&"free_cursor"), "Alt")
	assert_eq(UIKeyGlyph.label_for_action(&"toggle_cursor"), "Esc")
	assert_eq(UIKeyGlyph.label_for_action(&"shoulder_swap"), "V")
	assert_eq(UIKeyGlyph.label_for_action(&"toggle_debug"), "F3")
	assert_eq(UIKeyGlyph.label_for_action(&"open_settings"), "F10")
	assert_eq(UIKeyGlyph.label_for_action(&"zoom_in"), "Rueda ↑")
	assert_eq(UIKeyGlyph.label_for_action(&"zoom_out"), "Rueda ↓")


func test_the_glyph_reads_the_real_input_map_not_a_fixed_text() -> void:
	_bind([_key(KEY_F9)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "F9")
	_bind([_key(KEY_K, true, true)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Ctrl+Mayús+K", "with modifiers")
	_bind([_mouse(MOUSE_BUTTON_RIGHT)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Clic der.")
	_bind([_mouse(MOUSE_BUTTON_MIDDLE)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Clic central")
	_bind([_mouse(MOUSE_BUTTON_XBUTTON1)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Ratón 4")
	var pad: InputEventJoypadButton = InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_A
	_bind([pad])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Mando 0")
	_bind([_mouse(MOUSE_BUTTON_LEFT), pad, _key(KEY_Q)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Q", "keyboard takes priority over mouse and gamepad")
	_bind([pad, _mouse(MOUSE_BUTTON_RIGHT)])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "Clic der.", "and mouse over gamepad")
	var other: InputEventAction = InputEventAction.new()
	other.action = &"otra"
	_bind([other])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), UIKeyGlyph.UNASSIGNED_TEXT,
			"an event of another type does not work")
	_bind([])
	assert_eq(UIKeyGlyph.label_for_action(TEST_ACTION), "?", "with nothing assigned")
	assert_eq(UIKeyGlyph.label_for_action(&"accion_que_no_existe"), "?", "nor an action")


func test_key_labels_use_the_physical_key_and_never_fail_without_a_screen() -> void:
	# With the physical key, the glyph asks the system which letter is at that position (AZERTY); without a
	# screen it does not support it and the physical key's name is used (an engine error would make
	# the test fail).
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_W
	assert_eq(UIKeyGlyph.label_for_event(event), "W" if DisplayServer.get_name() == "headless"
			else UIKeyGlyph.label_for_event(event))
	var by_keycode: InputEventKey = InputEventKey.new()
	by_keycode.keycode = KEY_Z
	assert_eq(UIKeyGlyph.label_for_event(by_keycode), "Z", "a non-physical key, as is")
	var empty: InputEventKey = InputEventKey.new()
	assert_eq(UIKeyGlyph.label_for_event(empty), "", "with no key there is no text")
	assert_eq(UIKeyGlyph.label_for_event(InputEventMouseMotion.new()), "")


func test_key_and_mouse_names_are_in_spanish() -> void:
	assert_eq(UIKeyGlyph.key_name(KEY_SHIFT), "Mayús")
	assert_eq(UIKeyGlyph.key_name(KEY_SPACE), "Espacio")
	assert_eq(UIKeyGlyph.key_name(KEY_ENTER), "Intro")
	assert_eq(UIKeyGlyph.key_name(KEY_ESCAPE), "Esc")
	assert_eq(UIKeyGlyph.key_name(KEY_UP), "↑")
	assert_eq(UIKeyGlyph.key_name(KEY_F5), "F5", "the others, the engine's name")
	assert_eq(UIKeyGlyph.mouse_button_name(MOUSE_BUTTON_WHEEL_UP), "Rueda ↑")
	assert_eq(UIKeyGlyph.mouse_button_name(MOUSE_BUTTON_XBUTTON2), "Ratón 5")
	assert_eq(UIKeyGlyph.mouse_button_name(MOUSE_BUTTON_WHEEL_LEFT), "Ratón 6")


func test_the_glyph_node_follows_reassignments() -> void:
	_bind([_key(KEY_F9)])
	var glyph: UIKeyGlyph = UIKeyGlyph.for_action(TEST_ACTION)
	_add(glyph)
	assert_eq(glyph.get_label(), "F9")
	var narrow: float = glyph.get_combined_minimum_size().x
	_bind([_key(KEY_SHIFT, true)])
	assert_eq(glyph.get_label(), "F9", "it does not change until it is notified")
	UIKeyGlyph.refresh_all(tree)
	assert_eq(glyph.get_label(), "Ctrl+Mayús", "refresh_all re-reads the InputMap")
	assert_true(glyph.get_combined_minimum_size().x > narrow, "the key widens with the text")
	glyph.action = &"jump"
	assert_eq(glyph.get_label(), "Espacio")
	glyph.text_override = "Rueda"
	assert_eq(glyph.get_label(), "Rueda", "the fixed text wins")
	glyph.text_override = ""
	glyph.action = &""
	assert_eq(glyph.get_label(), "?")
	assert_eq(glyph.mouse_filter, Control.MOUSE_FILTER_IGNORE, "it does not swallow the mouse")
	var compact: UIKeyGlyph = UIKeyGlyph.for_action(&"jump", true)
	_add(compact)
	assert_true(compact.get_combined_minimum_size().y < glyph.get_combined_minimum_size().y,
			"the compact version is shorter")
	# Drawing them gives no errors.
	await wait_process_frames(2)


func test_glyphs_leave_the_refresh_group_when_freed() -> void:
	var glyph: UIKeyGlyph = UIKeyGlyph.for_action(&"jump")
	_add(glyph)
	assert_true(tree.get_nodes_in_group(UIKeyGlyph.GROUP).has(glyph))
	tree.root.remove_child(glyph)
	assert_false(tree.get_nodes_in_group(UIKeyGlyph.GROUP).has(glyph))
	_nodes.erase(glyph)
	glyph.free()
	UIKeyGlyph.refresh_all(tree)


# --- Hint line --------------------------------------------------------------------------------

func test_hint_bar_shows_the_real_keys_of_each_hint() -> void:
	var bar: UIHintBar = _add(UIHintBar.new()) as UIHintBar
	assert_eq(bar.get_hint_count(), UIHintBar.DEFAULT_HINTS.size())
	var text: String = bar.get_plain_text()
	assert_true(text.contains("Alt: Liberar cursor"), text)
	assert_true(text.contains("V: Cambiar hombro"), text)
	assert_true(text.contains("Rueda: Zoom"), "the zoom shows \"Rueda\" (wheel): " + text)
	assert_false(text.contains("Depuración"), "without the debug shortcut (UI-49): " + text)
	assert_false(text.contains("Soltar ratón"), "nor the release-the-mouse one (UI-49): " + text)
	assert_true(text.contains("F10: Ajustes"), text)
	assert_eq(bar.get_glyphs().size(), bar.get_hint_count())
	# Reassigning a key changes the line.
	InputMap.action_erase_events(&"shoulder_swap")
	InputMap.action_add_event(&"shoulder_swap", _key(KEY_X))
	bar.refresh()
	assert_true(bar.get_plain_text().contains("X: Cambiar hombro"), bar.get_plain_text())
	InputMap.action_erase_events(&"shoulder_swap")
	InputMap.action_add_event(&"shoulder_swap", _key(KEY_V))
	var custom: Array[Dictionary] = [{"action": &"jump", "text": "Saltar"}]
	bar.set_hints(custom)
	assert_eq(bar.get_hint_count(), 1)
	assert_eq(bar.get_plain_text(), "Espacio: Saltar")
	assert_eq(bar.mouse_filter, Control.MOUSE_FILTER_IGNORE)


func test_the_hud_help_line_uses_glyphs_instead_of_fixed_text() -> void:
	var scene_text: String = FileAccess.get_file_as_string(HUD_SCENE_PATH)
	assert_false(scene_text.contains("Alt: liberar cursor"), "the fixed text is no longer in the scene")
	var hud: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_add(hud)
	var bar: UIHintBar = hud.get_node(^"HintLabel") as UIHintBar
	assert_not_null(bar, "the HUD's help is a UIHintBar")
	assert_true(bar.get_hint_count() >= 4)
	assert_false(bar.visible, "the hint line starts hidden (UI-49)")
	assert_true(bar.get_plain_text().contains("Alt: Liberar cursor"), bar.get_plain_text())
	assert_true(bar.get_plain_text().contains("F10: Ajustes"), "includes the settings")
	for glyph: UIKeyGlyph in bar.get_glyphs():
		assert_true(glyph.compact)
		assert_false(glyph.get_label().is_empty())


# --- Sound hooks ------------------------------------------------------------------------------

func test_ui_sounds_count_events_and_stay_silent_without_files() -> void:
	assert_eq(UISounds.EVENTS.size(), 8)
	for event: StringName in UISounds.EVENTS:
		assert_eq(UISounds.get_play_count(event), 0)
		assert_null(UISounds.get_stream(event), "there are no real sounds yet (%s)" % event)
	assert_true(UISounds.play(UISounds.CLICK))
	assert_true(UISounds.play(UISounds.CLICK), "the click is not throttled")
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 2)
	UISounds.muted = true
	assert_false(UISounds.play(UISounds.CLICK), "muted")
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 2)
	UISounds.muted = false
	UISounds.reset()
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 0)


func test_repeated_hover_and_tick_events_are_throttled() -> void:
	assert_true(UISounds.play(UISounds.HOVER))
	assert_false(UISounds.play(UISounds.HOVER), "the second, right away, is throttled")
	assert_eq(UISounds.get_play_count(UISounds.HOVER), 1)
	assert_true(UISounds.play(UISounds.TICK))
	assert_false(UISounds.play(UISounds.TICK))
	assert_true(UISounds.play(UISounds.CONFIRM))
	assert_true(UISounds.play(UISounds.CONFIRM))


func test_ui_sounds_play_through_the_ui_bus_of_the_director() -> void:
	_director = AudioDirector.new()
	_director.load_volumes_on_ready = false
	_add(_director)
	var tone: AudioStreamWAV = ToneFixture.make_tone(660.0, 1.0)
	UISounds.set_stream(UISounds.CLICK, tone)
	assert_eq(UISounds.get_stream(UISounds.CLICK), tone)
	assert_true(UISounds.play(UISounds.CLICK))
	assert_eq(_director.get_active_voices(AudioDirector.Category.UI), 1, "an interface sound plays")
	var playing: AudioStreamPlayer = null
	for player: AudioStreamPlayer in _director.get_players_ui():
		if player.playing:
			playing = player
	assert_not_null(playing)
	assert_eq(playing.bus, AudioBuses.UI, "through the interface bus")
	assert_eq(playing.volume_db, 0.0)
	UISounds.set_stream(UISounds.HOVER, tone)
	UISounds.play(UISounds.HOVER)
	var quiet: float = 0.0
	for player: AudioStreamPlayer in _director.get_players_ui():
		if player.playing and player != playing:
			quiet = player.volume_db
	assert_eq(quiet, float(UISounds.VOLUMES_DB[UISounds.HOVER]), "hovering sounds quieter")
	UISounds.set_stream(UISounds.CLICK, null)
	assert_null(UISounds.get_stream(UISounds.CLICK), "it can be removed")


func test_buttons_and_sliders_are_hooked_to_their_sounds() -> void:
	var root: VBoxContainer = _add(VBoxContainer.new()) as VBoxContainer
	var button: Button = Button.new()
	var disabled: Button = Button.new()
	disabled.disabled = true
	var slider: HSlider = HSlider.new()
	root.add_child(button)
	root.add_child(disabled)
	root.add_child(slider)
	UISounds.hook_all(root)
	UISounds.hook_all(root)
	button.mouse_entered.emit()
	assert_eq(UISounds.get_play_count(UISounds.HOVER), 1, "a single connection per button")
	button.pressed.emit()
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 1)
	disabled.mouse_entered.emit()
	assert_eq(UISounds.get_play_count(UISounds.HOVER), 1, "a disabled button makes no sound")
	slider.value = 40.0
	assert_eq(UISounds.get_play_count(UISounds.TICK), 1, "the slider ticks")
	var late: Button = Button.new()
	root.add_child(late)
	UISounds.hook_button(late)
	late.pressed.emit()
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 2)


# --- Focus neighbors --------------------------------------------------------------------------

func test_a_row_and_a_column_are_chained_with_wrap() -> void:
	var box: HBoxContainer = _add(HBoxContainer.new()) as HBoxContainer
	var controls: Array[Control] = _buttons(box, 3)
	UIFocus.make_focusable(controls)
	UIFocus.chain_horizontal(controls)
	assert_eq(UIFocus.get_neighbor(controls[0], SIDE_RIGHT), controls[1])
	assert_eq(UIFocus.get_neighbor(controls[1], SIDE_RIGHT), controls[2])
	assert_eq(UIFocus.get_neighbor(controls[2], SIDE_RIGHT), controls[0], "the last wraps to the first")
	assert_eq(UIFocus.get_neighbor(controls[0], SIDE_LEFT), controls[2], "and vice versa")
	assert_eq(UIFocus.get_neighbor(controls[1], SIDE_LEFT), controls[0])
	assert_eq(controls[1].find_valid_focus_neighbor(SIDE_RIGHT), controls[2], "the engine uses it")
	UIFocus.chain_horizontal(controls, false)
	assert_null(UIFocus.get_neighbor(controls[2], SIDE_RIGHT), "without wrap, the ends have no neighbor")
	assert_null(UIFocus.get_neighbor(controls[0], SIDE_LEFT))
	assert_eq(UIFocus.get_neighbor(controls[0], SIDE_RIGHT), controls[1])
	UIFocus.chain_vertical(controls)
	assert_eq(UIFocus.get_neighbor(controls[0], SIDE_BOTTOM), controls[1])
	assert_eq(UIFocus.get_neighbor(controls[0], SIDE_TOP), controls[2])
	var alone: Array[Control] = [controls[0]]
	UIFocus.chain_horizontal(alone)
	assert_null(UIFocus.get_neighbor(controls[0], SIDE_RIGHT), "a single one is not its own neighbor")


func test_a_grid_links_rows_and_columns() -> void:
	var grid: GridContainer = _add(GridContainer.new()) as GridContainer
	grid.columns = 3
	var controls: Array[Control] = _buttons(grid, 5)
	UIFocus.grid(controls, 3)
	# Rows: 0 1 2 / 3 4.
	var expected: Dictionary = {
		0: {SIDE_LEFT: 2, SIDE_RIGHT: 1, SIDE_TOP: 3, SIDE_BOTTOM: 3},
		1: {SIDE_LEFT: 0, SIDE_RIGHT: 2, SIDE_TOP: 4, SIDE_BOTTOM: 4},
		2: {SIDE_LEFT: 1, SIDE_RIGHT: 0, SIDE_TOP: -1, SIDE_BOTTOM: -1},
		3: {SIDE_LEFT: 4, SIDE_RIGHT: 4, SIDE_TOP: 0, SIDE_BOTTOM: 0},
		4: {SIDE_LEFT: 3, SIDE_RIGHT: 3, SIDE_TOP: 1, SIDE_BOTTOM: 1},
	}
	_check_grid(controls, expected)
	UIFocus.grid(controls, 3, false)
	var no_wrap: Dictionary = {
		0: {SIDE_LEFT: -1, SIDE_RIGHT: 1, SIDE_TOP: -1, SIDE_BOTTOM: 3},
		1: {SIDE_LEFT: 0, SIDE_RIGHT: 2, SIDE_TOP: -1, SIDE_BOTTOM: 4},
		2: {SIDE_LEFT: 1, SIDE_RIGHT: -1, SIDE_TOP: -1, SIDE_BOTTOM: -1},
		3: {SIDE_LEFT: -1, SIDE_RIGHT: 4, SIDE_TOP: 0, SIDE_BOTTOM: -1},
		4: {SIDE_LEFT: 3, SIDE_RIGHT: -1, SIDE_TOP: 1, SIDE_BOTTOM: -1},
	}
	_check_grid(controls, no_wrap)
	UIFocus.grid(controls, 0)
	UIFocus.grid([] as Array[Control], 3)


func _check_grid(controls: Array[Control], expected: Dictionary) -> void:
	for index: int in expected:
		var sides: Dictionary = expected[index]
		for side: int in sides:
			var neighbor: Control = UIFocus.get_neighbor(controls[index], side as Side)
			var want: int = sides[side]
			if want < 0:
				assert_null(neighbor, "slot %d, side %d: no neighbor" % [index, side])
			else:
				assert_eq(neighbor, controls[want], "slot %d, side %d" % [index, side])


func test_focus_can_be_given_to_the_first_focusable_control() -> void:
	var root: VBoxContainer = _add(VBoxContainer.new()) as VBoxContainer
	var label: Label = Label.new()
	root.add_child(label)
	var hidden: Button = Button.new()
	hidden.visible = false
	root.add_child(hidden)
	var passive: Button = Button.new()
	passive.focus_mode = Control.FOCUS_NONE
	root.add_child(passive)
	assert_null(UIFocus.find_first_focusable(root), "none is focusable and visible")
	assert_null(UIFocus.focus_first(root))
	var button: Button = Button.new()
	root.add_child(button)
	assert_eq(UIFocus.find_first_focusable(root), button)
	assert_eq(UIFocus.focus_first(root), button)
	assert_true(button.has_focus())


func test_arrow_keys_move_the_focus_along_the_chain() -> void:
	var box: HBoxContainer = _add(HBoxContainer.new()) as HBoxContainer
	var controls: Array[Control] = _buttons(box, 3)
	UIFocus.chain_horizontal(controls)
	await wait_process_frames(1)
	controls[0].grab_focus()
	assert_true(controls[0].has_focus())
	_press_ui(KEY_RIGHT)
	assert_true(controls[1].has_focus(), "right moves to the next")
	_press_ui(KEY_RIGHT)
	_press_ui(KEY_RIGHT)
	assert_true(controls[0].has_focus(), "and wraps around")
	_press_ui(KEY_LEFT)
	assert_true(controls[2].has_focus(), "left, the opposite")


func _press_ui(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	tree.root.push_input(event)


func _buttons(parent: Node, count: int) -> Array[Control]:
	var result: Array[Control] = []
	for index: int in count:
		var button: Button = Button.new()
		button.text = str(index)
		button.focus_mode = Control.FOCUS_ALL
		parent.add_child(button)
		result.append(button)
	return result
