extends TestCase
## Regression tests for the Godot facts that the localization runtime ([L10n]) relies on
## (docs/localization.md section 4.1, checked on Godot 4.7.2). If an engine upgrade changes one of them,
## this file fails and the design has to be looked at again, instead of the game misbehaving silently.
## [br][br]
## It only talks to the engine and to a small fixture catalog ([code]tests/fixtures/l10n/fixture_es.po[/code]);
## the global locale and the translations it touches are restored when each test ends.

const FIXTURE: String = "res://tests/fixtures/l10n/fixture_es.po"
const TEST_DOMAIN: StringName = &"eldmark_test"


## A control that counts how many times the engine calls its [code]_draw[/code].
class DrawCounter extends Control:
	var draws: int = 0

	func _draw() -> void:
		draws += 1


## A label that counts the translation notifications it receives.
class CountingLabel extends Label:
	var changes: int = 0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_TRANSLATION_CHANGED:
			changes += 1


var _saved_locale: String = ""
var _nodes: Array[Node] = []
var _main_translations: Array[Translation] = []


func before_each() -> void:
	_saved_locale = TranslationServer.get_locale()


func after_each() -> void:
	for translation: Translation in _main_translations:
		TranslationServer.remove_translation(translation)
	_main_translations.clear()
	if TranslationServer.has_domain(TEST_DOMAIN):
		TranslationServer.remove_domain(TEST_DOMAIN)
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	TranslationServer.set_locale(_saved_locale)
	await wait_process_frames(1)


func _fixture() -> Translation:
	return load(FIXTURE) as Translation


func _domain() -> TranslationDomain:
	var domain: TranslationDomain = TranslationServer.get_or_add_domain(TEST_DOMAIN)
	domain.add_translation(_fixture())
	return domain


# --- Loading ----------------------------------------------------------------------------------

func test_a_po_file_loads_at_runtime_without_an_import() -> void:
	var translation: Translation = _fixture()
	if not assert_not_null(translation, "load() reads the .po file"):
		return
	assert_eq(translation.locale, "es", "the locale comes from the Language header")
	assert_false(FileAccess.file_exists(FIXTURE + ".import"), "and the file needs no .import")
	assert_eq(translation.get_message("Restore tab"), "Restaurar pestaña")
	assert_eq(translation.get_message("Off", &"shadows"), "Desactivadas", "context 'shadows'")
	assert_eq(translation.get_message("Off", &"vsync"), "Desactivada", "context 'vsync'")
	assert_eq(translation.get_message("Off"), "", "no entry without a context")


func test_escapes_are_decoded_but_unicode_escapes_are_not() -> void:
	var translation: Translation = _fixture()
	assert_eq(translation.get_message("Escapes: \"x\"\ttab \\ end"), "Escapes: \"x\"\tpestaña \\ fin",
			"\\n, \\t, \\\" and \\\\ are decoded")
	var source: String = "msgid \"\"\nmsgstr \"\"\n\"Language: es\\n\"\n\nmsgid \"Smile\"\nmsgstr \"\\u00f1\"\n"
	var po: Translation = _translation_from_text(source)
	assert_eq(po.get_message("Smile"), "\\u00f1", "\\uXXXX is not decoded: it stays as six characters")


# Loads a .po text through the engine (written to a temporary file).
func _translation_from_text(text: String) -> Translation:
	var path: String = "user://test_l10n_runtime.po"
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	var translation: Translation = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Translation
	DirAccess.remove_absolute(path)
	return translation


func test_get_message_is_empty_when_there_is_no_usable_entry() -> void:
	var translation: Translation = _fixture()
	assert_eq(translation.get_message("Not in the catalog"), "", "missing entry")
	assert_eq(translation.get_message("Untranslated"), "", "empty msgstr")
	assert_eq(translation.get_message("Fuzzy"), "", "fuzzy entry")
	assert_eq(translation.get_message("Audio"), "Audio", "a translation equal to the msgid is still a hit")


func test_plurals_use_the_header_rule() -> void:
	var translation: Translation = _fixture()
	var singular: String = "You can restore it for {days} day."
	var plural: String = "You can restore it for {days} days."
	assert_eq(translation.get_plural_message(singular, plural, 1), "Puedes restaurarlo durante {days} día.")
	assert_eq(translation.get_plural_message(singular, plural, 0), "Puedes restaurarlo durante {days} días.")
	assert_eq(translation.get_plural_message(singular, plural, 5), "Puedes restaurarlo durante {days} días.")
	assert_eq(translation.get_plural_message("Nope", "Nopes", 2), "", "missing plural entry")


# --- The private domain -----------------------------------------------------------------------

func test_a_private_domain_translates_with_context_and_plurals() -> void:
	var domain: TranslationDomain = _domain()
	TranslationServer.set_locale("es")
	assert_eq(domain.translate("Restore tab"), "Restaurar pestaña")
	assert_eq(domain.translate("Off", &"shadows"), "Desactivadas")
	assert_eq(domain.translate("Off", &"vsync"), "Desactivada")
	assert_eq(domain.translate("Nothing here"), "Nothing here", "a missing entry gives the msgid")
	var singular: String = "You can restore it for {days} day."
	var plural: String = "You can restore it for {days} days."
	assert_eq(domain.translate_plural(singular, plural, 1), "Puedes restaurarlo durante {days} día.")
	assert_eq(domain.translate_plural(singular, plural, 3), "Puedes restaurarlo durante {days} días.")


func test_a_private_domain_follows_the_global_locale() -> void:
	var domain: TranslationDomain = _domain()
	TranslationServer.set_locale("es_ES")
	assert_eq(domain.translate("Restore tab"), "Restaurar pestaña", "es_ES uses the es catalog")
	TranslationServer.set_locale("es_MX")
	assert_eq(domain.translate("Restore tab"), "Restaurar pestaña", "es_MX too")
	TranslationServer.set_locale("fr_FR")
	assert_eq(domain.translate("Restore tab"), "Restore tab", "a language with no catalog gets the msgid")
	TranslationServer.set_locale("en")
	assert_eq(domain.translate("Restore tab"), "Restore tab", "English too")


func test_the_main_domain_translates_orphan_nodes_but_a_private_one_does_not() -> void:
	assert_false(bool(ProjectSettings.get_setting("internationalization/rendering/root_node_auto_translate", true)),
			"the project turns root_node_auto_translate off")
	TranslationServer.set_locale("es")
	_domain()
	var orphan: Label = Label.new()
	var in_tree: Label = Label.new()
	_nodes.append(orphan)
	_nodes.append(in_tree)
	tree.root.add_child(in_tree)
	assert_eq(orphan.atr("Restore tab"), "Restore tab", "a private domain does not reach an orphan node")
	assert_eq(in_tree.atr("Restore tab"), "Restore tab", "nor a node in the tree")
	# A translation in the main domain does reach the orphan, whatever root_node_auto_translate says.
	var translation: Translation = _fixture()
	TranslationServer.add_translation(translation)
	_main_translations.append(translation)
	assert_eq(orphan.atr("Restore tab"), "Restaurar pestaña", "the main domain translates an orphan node")
	assert_eq(in_tree.atr("Restore tab"), "Restore tab", "but not one in the tree, with the root switch off")


func test_the_global_locale_is_normalised_and_the_os_locale_has_a_language_part() -> void:
	var language: String = OS.get_locale_language()
	assert_false(language.is_empty(), "the OS language is known")
	assert_false(language.contains("_"), "get_locale_language() is only the language code")
	assert_true(OS.get_locale().begins_with(language), "OS.get_locale() starts with that code")


# --- Notifications ----------------------------------------------------------------------------

func test_set_locale_notifies_the_tree_only_when_the_locale_changes() -> void:
	TranslationServer.set_locale("es")
	var label: CountingLabel = CountingLabel.new()
	tree.root.add_child(label)
	_nodes.append(label)
	label.changes = 0
	TranslationServer.set_locale("es")
	assert_eq(label.changes, 0, "es to es does not notify")
	TranslationServer.set_locale("en")
	assert_eq(label.changes, 1, "es to en notifies")
	TranslationServer.set_locale("en_US")
	assert_eq(label.changes, 2, "en to en_US notifies although both are English")
	TranslationServer.set_locale("en_US")
	assert_eq(label.changes, 2, "the same string again does not")


func test_the_notification_also_goes_out_when_the_main_domain_is_empty() -> void:
	assert_true(TranslationServer.get_loaded_locales().is_empty(), "nothing is loaded in the main domain")
	TranslationServer.set_locale("es")
	var label: CountingLabel = CountingLabel.new()
	tree.root.add_child(label)
	_nodes.append(label)
	label.changes = 0
	TranslationServer.set_locale("en")
	assert_eq(label.changes, 1, "a locale change notifies although the main domain is empty")


func test_groups_only_list_nodes_in_the_tree() -> void:
	var inside: Label = Label.new()
	var outside: Label = Label.new()
	inside.add_to_group(&"l10n_runtime_probe")
	outside.add_to_group(&"l10n_runtime_probe")
	tree.root.add_child(inside)
	_nodes.append(inside)
	_nodes.append(outside)
	var found: Array[Node] = tree.get_nodes_in_group(&"l10n_runtime_probe")
	assert_true(found.has(inside), "a node in the tree is listed")
	assert_false(found.has(outside), "an orphan is not: bound nodes outside the tree must reapply on re-entry")


# --- Pseudolocalization and drawing -----------------------------------------------------------

func test_the_engine_pseudolocalization_breaks_placeholders_and_bbcode() -> void:
	# This is why L10n has its own pseudolocalization instead of switching the engine's on.
	var text: String = "Free slots: {free} of %d [b]Bold[/b]"
	var engine_text: String = TranslationServer.pseudolocalize(text)
	assert_true(engine_text != text, "the engine does change the text")
	assert_false(engine_text.contains("{free}") and engine_text.contains("[b]Bold[/b]") and engine_text.contains("%d"),
			"and it does not leave every placeholder and tag intact: %s" % engine_text)


func test_draw_runs_in_headless_after_queue_redraw() -> void:
	# The screen tests rely on _draw running without a window to record the strings drawn with UIFonts.
	var control: DrawCounter = DrawCounter.new()
	control.size = Vector2(40.0, 40.0)
	tree.root.add_child(control)
	_nodes.append(control)
	await wait_process_frames(2)
	control.draws = 0
	control.queue_redraw()
	await wait_process_frames(2)
	assert_true(control.draws >= 1, "_draw ran after queue_redraw (draws: %d)" % control.draws)
