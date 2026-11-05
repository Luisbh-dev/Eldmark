extends TestCase
## Screen tests for localization (docs/localization.md section 12.2).
## [br][br]
## [b]Spanish snapshot.[/b] Each screen in [constant SCREENS] is built with fixed data and its visible texts
## are collected ([L10nScreenProbe]); the result must equal [code]tests/l10n_golden/<screen>.es.txt[/code]. The
## golden files were written from the Spanish literals before the screen was migrated, so they prove that
## Spanish players see exactly what they saw. Running the runner with
## [code]-- --l10n-write-golden[/code] rewrites them (only to be reviewed in a commit of their own).

const GOLDEN_DIR: String = "res://tests/l10n_golden"
const WRITE_GOLDEN_ARG: String = "--l10n-write-golden"
const SETTINGS_PATH: String = "user://test_l10n_screens.cfg"

## Screen id -> what to build. Ids are the golden file names.
const SCREENS: Array[StringName] = [
	&"settings_graphics", &"settings_audio", &"settings_camera", &"settings_interface",
	&"settings_confirm",
]

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
