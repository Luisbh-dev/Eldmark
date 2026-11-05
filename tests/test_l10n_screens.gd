extends TestCase
## Screen tests for localization (docs/localization.md section 12.2).
## [br][br]
## [b]Spanish snapshot.[/b] Each screen in [constant SCREENS] is built with fixed data and its visible texts
## are collected ([L10nScreenProbe]); the result must equal [code]tests/l10n_golden/<screen>.es.txt[/code]. The
## golden files were written from the Spanish literals before the screen was migrated, so they prove that
## Spanish players see exactly what they saw. Running the runner with
## [code]-- --l10n-write-golden[/code] rewrites them (only to be reviewed in a commit of their own).
## [br][br]
## [b]Pseudo refresh.[/b] The screen is built in English and switched to [code]pseudo[/code] while it is open;
## every visible text with a letter or a digit, and every drawn string, must come out wrapped in
## [code]¦…¦[/code]. That proves the text goes through [L10n] and refreshes. The settings window is also
## switched from its own language selector, which must not rebuild any control.

const GOLDEN_DIR: String = "res://tests/l10n_golden"
const WRITE_GOLDEN_ARG: String = "--l10n-write-golden"
const SETTINGS_PATH: String = "user://test_l10n_screens.cfg"

## Screen id -> what to build. Ids are the golden file names.
const SCREENS: Array[StringName] = [
	&"settings_graphics", &"settings_audio", &"settings_camera", &"settings_interface",
	&"settings_confirm",
]

## Screens that cannot be open while the language changes (modal dialogs): they translate when they open, so
## the pseudo check opens them again after the switch. The reason goes next to each one.
const L10N_REFRESH_ON_OPEN: Dictionary = {
	&"settings_confirm": "UIConfirmDialog is modal: it translates its texts when it opens",
}
## Option items that are shown as they are in every language (endonyms): pseudolocalization skips them.
const ENDONYMS: Array[String] = ["Español"]

var _nodes: Array[Node] = []
var _settings: ClientSettings = null


func before_each() -> void:
	InputBindings.ensure_defaults()
	UISounds.reset()
	_remove_settings_file()
	_settings = ClientSettings.load_from(SETTINGS_PATH)
	ClientSettings.set_current(_settings)


func after_each() -> void:
	_free_screens()
	ClientSettings.set_current(null)
	_settings = null
	UISounds.reset()
	_remove_settings_file()
	await wait_process_frames(2)


func _remove_settings_file() -> void:
	if FileAccess.file_exists(SETTINGS_PATH):
		DirAccess.remove_absolute(SETTINGS_PATH)


# Builds screen [param id] in the tree and returns the node whose subtree holds its texts.
func _build(id: StringName) -> Node:
	var confirm: UIConfirmDialog = UIConfirmDialog.new()
	tree.root.add_child(confirm)
	_nodes.append(confirm)
	var menu: SettingsMenu = SettingsMenu.new()
	tree.root.add_child(menu)
	_nodes.append(menu)
	menu.setup(_settings, confirm)
	if id == &"settings_confirm":
		menu.restore_all()
		return confirm
	menu.open()
	menu.show_tab(StringName(String(id).trim_prefix("settings_")))
	return menu


func _snapshot(id: StringName) -> PackedStringArray:
	var root: Node = _build(id)
	return L10nScreenProbe.collect(root)


func _golden_path(id: StringName) -> String:
	return "%s/%s.es.txt" % [GOLDEN_DIR, id]


func _read_golden(id: StringName) -> PackedStringArray:
	var text: String = FileAccess.get_file_as_string(_golden_path(id))
	var lines: PackedStringArray = text.split("\n")
	if not lines.is_empty() and lines[lines.size() - 1].is_empty():
		lines.remove_at(lines.size() - 1)
	return lines


func _write_golden(id: StringName, lines: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GOLDEN_DIR))
	var file: FileAccess = FileAccess.open(_golden_path(id), FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()


func test_spanish_snapshots_match_the_golden_files() -> void:
	with_locale("es")
	var writing: bool = OS.get_cmdline_user_args().has(WRITE_GOLDEN_ARG)
	for id: StringName in SCREENS:
		var lines: PackedStringArray = _snapshot(id)
		_free_screens()
		await wait_process_frames(1)
		if writing:
			_write_golden(id, lines)
		if not assert_true(FileAccess.file_exists(_golden_path(id)), "%s has a golden file" % id):
			continue
		var expected: PackedStringArray = _read_golden(id)
		if not assert_eq(lines.size(), expected.size(), "%s: number of texts" % id):
			assert_eq("\n".join(lines), "\n".join(expected), "%s: the texts" % id)
			continue
		for index: int in lines.size():
			assert_eq(lines[index], expected[index], "%s: text %d" % [id, index])


# Frees what the last screen built so that the next one starts from scratch.
func _free_screens() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	UISounds.reset()


func test_every_visible_text_goes_through_l10n_and_refreshes_in_pseudo() -> void:
	for id: StringName in SCREENS:
		var root: Node = _build(id)
		await wait_process_frames(1)
		L10n.force("pseudo")
		await wait_process_frames(1)
		if L10N_REFRESH_ON_OPEN.has(id):
			_free_screens()
			root = _build(id)
			await wait_process_frames(1)
		var lines: PackedStringArray = L10nScreenProbe.collect(root, L10n.take_drawn())
		var checked: int = 0
		for line: String in L10nScreenProbe.texts_with_content(lines):
			var kind: String = line.get_slice(L10nScreenProbe.SEPARATOR, 0)
			var text: String = line.get_slice(L10nScreenProbe.SEPARATOR, 1)
			if kind == "option_item" and ENDONYMS.has(text):
				continue
			checked += 1
			assert_true(text.begins_with(L10n.PSEUDO_OPEN) and text.ends_with(L10n.PSEUDO_CLOSE),
					"%s: \"%s\" is not pseudolocalized (it skipped L10n or does not refresh)" % [id, text])
		assert_true(checked > 0, "%s has texts to check" % id)
		_free_screens()
		L10n.force("en")
		await wait_process_frames(1)


func test_the_language_selector_switches_the_open_window_without_rebuilding_it() -> void:
	# Lift the runner's fixed language: here the setting, through the selector, is in charge. The handler
	# applies each change like ClientServices does.
	L10n.force("")
	L10n.set_language("en")
	L10n.flush()
	_settings.changed.connect(func(id: StringName, _value: Variant) -> void:
		_settings.apply_value(id, tree))
	var menu: SettingsMenu = _build(&"settings_interface") as SettingsMenu
	await wait_process_frames(1)
	var selector: OptionButton = menu.get_control(ClientSettings.LANGUAGE) as OptionButton
	var items_before: int = selector.item_count
	assert_eq(menu.window_title, "Settings")
	assert_eq(menu.get_tabs().get_tab_title(0), "Graphics")
	assert_eq(selector.get_item_text(0), "Automatic (Spanish)")
	selector.select(2)
	selector.item_selected.emit(2)
	assert_eq(_settings.get_value(ClientSettings.LANGUAGE), "es", "the selector changed the setting")
	assert_eq(menu.window_title, "Settings", "the switch is deferred: nothing is rewritten inside the signal")
	await wait_process_frames(2)
	assert_eq(L10n.language(), "es")
	assert_eq(menu.window_title, "Ajustes", "the open window is in Spanish")
	assert_eq(menu.get_tabs().get_tab_title(0), "Gráficos")
	assert_eq(selector.get_item_text(0), "Automático (español)")
	assert_eq(menu.get_restore_tab_button().text, "Restaurar pestaña")
	assert_true(menu.get_control(ClientSettings.LANGUAGE) == selector, "the selector is the same node")
	assert_eq(selector.item_count, items_before, "with the same items")
	assert_eq(selector.selected, 2, "and the same choice")
	# What it shows is what the Spanish snapshot says.
	var expected: PackedStringArray = _read_golden(&"settings_interface")
	assert_eq("\n".join(L10nScreenProbe.collect(menu)), "\n".join(expected), "the same as the Spanish golden file")
	# Back to English from the same selector, and "Restore all" leaves the choice alone.
	selector.select(1)
	selector.item_selected.emit(1)
	await wait_process_frames(2)
	assert_eq(L10n.language(), "en")
	assert_eq(menu.window_title, "Settings")
	menu.get_restore_all_button().pressed.emit()
	await wait_process_frames(2)
	assert_eq(_settings.get_value(ClientSettings.LANGUAGE), "en", "restore all does not touch the language")
	L10n.set_language("auto")
	L10n.flush()
