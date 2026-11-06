extends TestCase
## Tests for [L10n], the interface localization runtime (docs/localization.md section 4): lookups with
## context, plurals and named placeholders, the language rules (forced, saved, deferred), live binding,
## pseudolocalization, strict mode and number formatting.
## [br][br]
## Most tests use a small fixture catalog instead of [code]locale/es.po[/code], so they do not break when a
## translation is edited, and turn strict mode off (the runner turns it on before every test, and a
## fixture entry has no counterpart in the real catalog). The strict-mode tests turn it on again.

const FIXTURE: String = "res://tests/fixtures/l10n/fixture_es.po"


## A label that counts the translation notifications it receives.
class CountingLabel extends Label:
	var changes: int = 0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_TRANSLATION_CHANGED:
			changes += 1


var _nodes: Array[Node] = []


func before_each() -> void:
	L10n.set_strict(false)
	L10n.use_spanish_catalog(load(FIXTURE) as Translation)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	L10n.use_spanish_catalog(null)
	L10n.force("en")
	await wait_process_frames(1)


func _track(node: Node, in_tree: bool = true) -> Node:
	_nodes.append(node)
	if in_tree:
		tree.root.add_child(node)
	return node


# --- Lookups ----------------------------------------------------------------------------------

func test_a_text_is_the_msgid_in_english_and_the_catalog_entry_in_spanish() -> void:
	assert_eq(L10n.t("Restore tab"), "Restore tab")
	with_locale("es")
	assert_eq(L10n.t("Restore tab"), "Restaurar pestaña")
	assert_eq(L10n.t("Not in the catalog"), "Not in the catalog", "a missing entry shows correct English")
	assert_eq(L10n.t("Untranslated"), "Untranslated", "so does an empty msgstr")
	assert_eq(L10n.t("Fuzzy"), "Fuzzy", "and a fuzzy one")
	assert_eq(L10n.t("Audio"), "Audio", "a translation equal to the msgid is a hit")
	assert_eq(L10n.t(""), "", "the empty text stays empty")


func test_the_context_tells_apart_what_english_merges() -> void:
	with_locale("es")
	assert_eq(L10n.t("Off", &"shadows"), "Desactivadas")
	assert_eq(L10n.t("Off", &"vsync"), "Desactivada")
	assert_eq(L10n.t("Off"), "Off", "with no context there is no entry")
	assert_eq(L10n.mark("Off", &"vsync"), "Off", "mark() returns the msgid unchanged")


func test_plurals_follow_the_language_rule() -> void:
	var one: String = "You can restore it for {days} day."
	var many: String = "You can restore it for {days} days."
	assert_eq(L10n.tn(one, many, 1), one, "English singular")
	assert_eq(L10n.tn(one, many, 0), many, "English plural for zero")
	assert_eq(L10n.tn(one, many, 5), many)
	with_locale("es")
	assert_eq(L10n.tn(one, many, 1), "Puedes restaurarlo durante {days} día.")
	assert_eq(L10n.tn(one, many, 2), "Puedes restaurarlo durante {days} días.")
	assert_eq(L10n.tfn(one, many, 3, {"days": 3}), "Puedes restaurarlo durante 3 días.")
	assert_eq(L10n.tn("Missing", "Missings", 1), "Missing", "a missing plural falls back to English")
	assert_eq(L10n.tn("Missing", "Missings", 2), "Missings")


func test_named_placeholders_are_replaced_in_a_single_pass() -> void:
	assert_eq(L10n.tf("Free slots: {free} of {total}", {"free": 2, "total": 3}), "Free slots: 2 of 3")
	with_locale("es")
	assert_eq(L10n.tf("Free slots: {free} of {total}", {"free": 2, "total": 3}), "Huecos libres: 2 de 3")
	assert_eq(L10n.tf("Free slots: {free} of {total}", {"free": "{total}", "total": 9}), "Huecos libres: {total} de 9",
			"a value that looks like a placeholder is not expanded a second time")
	assert_eq(L10n.tf("Free slots: {free} of {total}", {"free": 1}), "Huecos libres: 1 de {total}",
			"a placeholder with no value stays as it is")
	assert_eq(L10n.tf("Escapes: \"x\"\ttab \\ end", {}), "Escapes: \"x\"\tpestaña \\ fin")


# --- Language rules ---------------------------------------------------------------------------

func test_a_forced_language_wins_over_the_saved_setting() -> void:
	L10n.force("es")
	L10n.set_language("en")
	L10n.flush()
	assert_eq(L10n.language(), "es", "the forced language rules")
	L10n.force("")
	assert_eq(L10n.language(), "en", "lifting it lets the saved setting through")
	L10n.set_language("es")
	assert_eq(L10n.language(), "es")
	L10n.set_language("klingon")
	assert_eq(L10n.language(), "es", "an unknown value counts as automatic, which is Spanish until UI-39")
	L10n.force("klingon")
	assert_eq(L10n.forced(), "", "an unknown forced code lifts the forcing")


func test_automatic_means_spanish_on_any_machine_until_the_final_review() -> void:
	assert_false(L10n.AUTO_FOLLOWS_OS, "UI-39 flips this constant, and then this test with it")
	L10n.force("")
	L10n.set_language("auto")
	assert_eq(L10n.language(), "es")
	L10n.set_language("en")
	L10n.flush()
	assert_eq(L10n.language(), "en")


func test_pseudo_is_english_with_pseudolocalization_on() -> void:
	L10n.force("pseudo")
	assert_eq(L10n.language(), "en", "it looks the English text up")
	assert_true(L10n.is_pseudo())
	L10n.force("en")
	assert_false(L10n.is_pseudo())


func test_set_language_is_deferred_and_flush_applies_it() -> void:
	L10n.force("")
	L10n.set_language("en")
	L10n.flush()
	var label: Label = _track(Label.new()) as Label
	L10n.bind(label, "Restore tab")
	assert_eq(label.text, "Restore tab")
	L10n.set_language("es")
	assert_eq(L10n.language(), "es", "the language in use changes at once")
	assert_eq(label.text, "Restore tab", "but the bound nodes wait for the end of the frame")
	await wait_process_frames(2)
	assert_eq(label.text, "Restaurar pestaña", "and then follow it")


func test_switching_notifies_the_tree_even_when_only_pseudo_changes() -> void:
	L10n.force("en")
	var watcher: CountingLabel = _track(CountingLabel.new()) as CountingLabel
	watcher.changes = 0
	L10n.force("es")
	assert_eq(watcher.changes, 1, "a language change notifies the tree")
	L10n.force("pseudo")
	assert_eq(watcher.changes, 2, "pseudo on notifies although the locale string is now en again")
	L10n.force("en")
	assert_eq(watcher.changes, 3, "pseudo off notifies although the locale string did not change")
	L10n.force("en")
	assert_eq(watcher.changes, 3, "forcing the same thing again does nothing")


# --- Binding ----------------------------------------------------------------------------------

func test_bind_sets_the_text_now_and_on_every_change() -> void:
	var button: Button = _track(Button.new()) as Button
	L10n.bind(button, "Restore tab")
	assert_eq(button.text, "Restore tab")
	L10n.bind(button, "Off", &"shadows", &"tooltip_text")
	assert_eq(button.tooltip_text, "Off", "several properties of one node can be bound")
	with_locale("es")
	assert_eq(button.text, "Restaurar pestaña")
	assert_eq(button.tooltip_text, "Desactivadas")
	L10n.force("pseudo")
	assert_true(button.text.begins_with(L10n.PSEUDO_OPEN), "pseudo too")


func test_a_bound_node_outside_the_tree_catches_up_when_it_comes_back() -> void:
	var pooled: Label = _track(Label.new(), false) as Label
	L10n.bind(pooled, "Restore tab")
	with_locale("es")
	assert_eq(pooled.text, "Restore tab", "an orphan is not in the group, so the switch skipped it")
	tree.root.add_child(pooled)
	assert_eq(pooled.text, "Restaurar pestaña", "it reapplies on entering the tree")
	tree.root.remove_child(pooled)
	with_locale("en")
	tree.root.add_child(pooled)
	assert_eq(pooled.text, "Restore tab", "every time it comes back")


func test_unbind_stops_the_refreshing() -> void:
	var label: Label = _track(Label.new()) as Label
	L10n.bind(label, "Restore tab")
	L10n.unbind(label)
	label.text = "mine"
	with_locale("es")
	assert_eq(label.text, "mine")


func test_bind_scene_binds_the_texts_of_a_scene_and_skips_raw_nodes() -> void:
	var root: Control = _track(Control.new()) as Control
	var title: Label = Label.new()
	title.text = "Restore tab"
	root.add_child(title)
	var name_label: Label = Label.new()
	name_label.text = "Bruno"
	name_label.set_meta(&"l10n_raw", true)
	root.add_child(name_label)
	var ctx_label: Label = Label.new()
	ctx_label.text = "Off"
	ctx_label.set_meta(&"l10n_ctx", &"shadows")
	root.add_child(ctx_label)
	var field: LineEdit = LineEdit.new()
	field.placeholder_text = "Restore tab"
	field.text = "typed by the player"
	root.add_child(field)
	L10n.bind_scene(root)
	L10n.bind_scene(root)
	with_locale("es")
	assert_eq(title.text, "Restaurar pestaña")
	assert_eq(name_label.text, "Bruno", "text written by people is never translated")
	assert_eq(ctx_label.text, "Desactivadas", "the context comes from the metadata")
	assert_eq(field.placeholder_text, "Restaurar pestaña")
	assert_eq(field.text, "typed by the player", "the text of a LineEdit is data")


func test_raw_marks_a_node() -> void:
	var label: Label = _track(Label.new()) as Label
	L10n.raw(label)
	assert_true(label.has_meta(L10n.RAW_META))


# --- Pseudolocalization -----------------------------------------------------------------------

func test_pseudolocalization_keeps_placeholders_bbcode_and_line_breaks() -> void:
	var text: String = L10n.pseudolocalize("Free slots: {free} of %d\n[b]Bold[/b] [color=#ff0000]red[/color] 100%%")
	assert_true(text.begins_with("¦") and text.ends_with("¦"), "wrapped in the marks")
	for kept: String in ["{free}", "%d", "\n", "[b]", "[/b]", "[color=#ff0000]", "[/color]", "%%"]:
		assert_true(text.contains(kept), "%s survives" % kept)
	assert_true(text.contains("Fréé"), "the letters of the literal parts get accents")
	assert_true(text.contains("~"), "and the text grows")
	assert_eq(L10n.pseudolocalize(""), "", "an empty text stays empty")


func test_pseudolocalization_only_uses_latin_1_letters_and_grows_30_percent() -> void:
	var source: String = "The quick brown fox jumps over the lazy dog. Cinnamon nuances."
	var text: String = L10n.pseudolocalize(source)
	for i: int in text.length():
		assert_true(text.unicode_at(i) <= 0xFF or text[i] == "~" or text[i] == "¦", "U+%04X is Latin-1" % text.unicode_at(i))
	var fill: int = text.count("~")
	assert_eq(fill, ceili(source.length() * L10n.PSEUDO_GROWTH), "30 % longer, counted over the literal text")
	for letter: String in L10n.PSEUDO_MAP.values():
		assert_true(letter.unicode_at(0) <= 0xFF)


func test_pseudo_goes_through_every_lookup_and_not_through_the_separators() -> void:
	L10n.force("pseudo")
	assert_eq(L10n.t("Restore tab"), "¦Réstóré táb~~~~¦")
	assert_eq(L10n.tn("%d day", "%d days", 1) % 1, "¦1 dáý~~¦", "plural, singular")
	assert_eq(L10n.tn("%d day", "%d days", 3) % 3, "¦3 dáýs~~¦", "plural, plural form")
	assert_eq(L10n.tf("Free slots: {free} of {total}", {"free": 2, "total": 3}),
			"¦Fréé slóts: 2 óf 3~~~~~¦", "parameters are inserted after the literal parts")
	assert_eq(L10n.tf("Hello, {name}", {"name": "Álvaro"}), "¦Hélló, Álvaro~~~¦", "a player name stays readable")
	assert_eq(L10n.format_int(12500), "¦12,500~~¦", "number helpers are wrapped as well, with the English separator")
	assert_eq(L10n.format_percent(0.5), "¦50%~¦")


# --- Strict mode ------------------------------------------------------------------------------

func test_strict_mode_records_lookups_with_no_spanish_entry() -> void:
	allow_logged_errors()
	L10n.set_strict(true)
	L10n.take_misses()
	assert_eq(L10n.t("Restore tab"), "Restore tab", "a pair with an entry is fine in English too")
	assert_true(L10n.take_misses().is_empty())
	L10n.t("Not in the catalog")
	L10n.t("Not in the catalog")
	L10n.t("Off", &"typo_context")
	L10n.t("Untranslated")
	L10n.t("Fuzzy")
	L10n.tn("Missing", "Missings", 2)
	var misses: PackedStringArray = L10n.take_misses()
	assert_eq(misses.size(), 5, "once per entry, and empty or fuzzy entries count as missing: %s" % [misses])
	assert_true(L10n.take_misses().is_empty(), "taking them clears them")
	L10n.t("Restore tab")
	L10n.tf("Free slots: {free} of {total}", {"free": 1, "total": 2})
	assert_true(L10n.take_misses().is_empty(), "present entries are not misses")


func test_strict_mode_checks_the_pair_whatever_the_language_in_use() -> void:
	allow_logged_errors()
	L10n.set_strict(true)
	L10n.take_misses()
	with_locale("es")
	L10n.t("Not in the catalog")
	assert_eq(L10n.take_misses().size(), 1, "also in Spanish")
	L10n.force("pseudo")
	L10n.t("Not in the catalog")
	assert_eq(L10n.take_misses().size(), 1, "and in pseudo")


func test_the_real_catalog_has_the_entries_the_formatting_helpers_need() -> void:
	L10n.use_spanish_catalog(null)
	L10n.set_strict(true)
	L10n.take_misses()
	L10n.format_int(1234567)
	L10n.format_decimal(1.5, 1)
	L10n.format_percent(0.5)
	L10n.format_multiplier(1.5)
	L10n.format_duration(3725)
	L10n.format_duration(125)
	L10n.format_duration(45)
	L10n.format_duration(7200)
	L10n.quote("x")
	assert_true(L10n.take_misses().is_empty(), "locale/es.po has every formatting entry")


func test_drawn_text_is_recorded_only_in_strict_mode() -> void:
	L10n.set_strict(false)
	L10n.take_drawn()
	L10n.note_drawn(null, "ignored")
	assert_true(L10n.take_drawn().is_empty())
	L10n.set_strict(true)
	L10n.note_drawn(null, "Restore tab")
	L10n.note_drawn(null, "Restore tab")
	assert_eq(L10n.take_drawn(), PackedStringArray(["Restore tab"]), "once each")


# --- Numbers ----------------------------------------------------------------------------------

func test_numbers_use_the_separators_of_the_language() -> void:
	L10n.use_spanish_catalog(null)
	assert_eq(L10n.format_int(12500), "12,500")
	assert_eq(L10n.format_int(-1234567), "-1,234,567")
	assert_eq(L10n.format_int(999), "999")
	assert_eq(L10n.format_decimal(1.25, 2), "1.25")
	assert_eq(L10n.format_multiplier(1.25), "x1.25")
	assert_eq(L10n.format_percent(0.75), "75%")
	with_locale("es")
	assert_eq(L10n.format_int(12500), "12.500")
	assert_eq(L10n.format_int(-1234567), "-1.234.567")
	assert_eq(L10n.format_decimal(1.25, 2), "1,25")
	assert_eq(L10n.format_decimal(3.0, 0), "3")
	assert_eq(L10n.format_multiplier(1.25), "x1,25")
	assert_eq(L10n.format_percent(0.75), "75 %")
	assert_eq(L10n.format_unit("{value} m", "60"), "60 m")


func test_durations_use_the_same_abbreviations_in_both_languages() -> void:
	L10n.use_spanish_catalog(null)
	for code: String in ["en", "es"]:
		with_locale(code)
		assert_eq(L10n.format_duration(45), "45 s", code)
		assert_eq(L10n.format_duration(300), "5 min", code)
		assert_eq(L10n.format_duration(7200), "2 h", code)
		assert_eq(L10n.format_duration(7800), "2 h 10 min", code)
		assert_eq(L10n.format_duration(-5), "0 s", code)


func test_quotes_and_bbcode_escapes() -> void:
	L10n.use_spanish_catalog(null)
	assert_eq(L10n.quote("hola"), "“hola”")
	with_locale("es")
	assert_eq(L10n.quote("hola"), "«hola»")
	assert_eq(L10n.escape_bbcode("[b]x[/b]"), "[lb]b]x[lb]/b]")
	var label: RichTextLabel = _track(RichTextLabel.new()) as RichTextLabel
	label.bbcode_enabled = true
	label.text = "Name: " + L10n.escape_bbcode("[color=red]Eve[/color]")
	assert_eq(label.get_parsed_text(), "Name: [color=red]Eve[/color]", "a player's brackets cannot open tags")
