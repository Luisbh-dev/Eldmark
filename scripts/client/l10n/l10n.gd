class_name L10n
extends RefCounted
## Interface localization runtime (UI-57, docs/localization.md section 4).
## [br][br]
## Every text the player reads goes through this static class. The catalog ([code]locale/es.po[/code]) is
## loaded into a private [TranslationDomain] ([constant DOMAIN]) and nothing is put in the engine's main
## domain, so the engine never translates a node by itself: [method t] and its siblings are the only way text
## gets translated, and [code]tr()[/code] is banned. The [code]msgid[/code] is the English text; a missing
## translation shows correct English.
## [br][br]
## [b]Language.[/b] [method force] fixes the language for the run ([code]--locale=[/code] and the test
## runner) and wins over everything; [method set_language] applies the saved setting
## ([code]auto[/code], [code]en[/code] or [code]es[/code]) unless a language is forced. Until UI-39,
## [code]auto[/code] means Spanish ([constant AUTO_FOLLOWS_OS]). The language switches live: [method
## set_language] is deferred to the end of the frame (the usual caller is the language selector itself),
## [method force] and [method flush] apply at once. Applying refreshes the nodes registered with
## [method bind], sets the engine's locale (which notifies the tree) or, when the locale string does not
## change (pseudolocalization on or off), propagates [constant Node.NOTIFICATION_TRANSLATION_CHANGED] by
## itself. Owners of text with values listen to that notification and rewrite their texts in place.
## [br][br]
## [b]Pseudolocalization.[/b] The forced language [code]pseudo[/code] looks the English text up, then
## accents the letters of its literal parts (Latin-1 only, which every UI font has), makes it 30 % longer
## with [code]~[/code] and wraps it in [code]¦…¦[/code]. Placeholders ([code]{name}[/code], [code]%d[/code],
## [code]%%[/code]), BBCode tags and line breaks are kept. The engine's own pseudolocalization is not used
## (it breaks placeholders and BBCode).
## [br][br]
## [b]Strict mode.[/b] With [method set_strict], every lookup checks that its (context, [code]msgid[/code])
## has a non-empty entry in the Spanish catalog, whatever the language in use, and records the misses for
## [method take_misses]. The test runner turns it on before each test. It also records the strings drawn
## with [method note_drawn].
## [br][br]
## Client only: [code]scripts/shared[/code], [code]scripts/world[/code] and [code]scripts/server[/code] never
## produce text for players (checked by [code]tests/test_architecture.gd[/code]).

## Name of the private translation domain.
const DOMAIN: StringName = &"eldmark"
## Spanish catalog, loaded on first use.
const SPANISH_PATH: String = "res://locale/es.po"
## Languages that have a catalog (English is the [code]msgid[/code] itself).
const LANGUAGES: Array[String] = ["en", "es"]
## Values of [code]--locale=[/code]: the two languages and pseudolocalized English.
const FORCEABLE: Array[String] = ["en", "es", "pseudo"]
## Values of the saved setting.
const SETTING_VALUES: Array[String] = ["auto", "en", "es"]
## Whether [code]auto[/code] follows the operating system's language. [code]false[/code] until the final
## review (UI-39): [code]auto[/code] means Spanish, so nobody sees a half-translated game by accident.
const AUTO_FOLLOWS_OS: bool = false
## Language [code]auto[/code] means while [constant AUTO_FOLLOWS_OS] is false, and the fallback for
## operating system languages with no catalog.
const AUTO_LANGUAGE: String = "es"
const LOCALE_ARG_PREFIX: String = "--locale="
const STRICT_ARG: String = "--l10n-strict"
## Group of the nodes registered with [method bind].
const BOUND_GROUP: StringName = &"l10n_bound"
## Metadata of a node that holds text written by a player or by staff: never translated.
const RAW_META: StringName = &"l10n_raw"
const _BINDS_META: StringName = &"l10n_binds"
const _HOOKED_META: StringName = &"l10n_hooked"
## Pseudolocalization: marks and growth.
const PSEUDO_OPEN: String = "¦"
const PSEUDO_CLOSE: String = "¦"
const PSEUDO_FILL: String = "~"
const PSEUDO_GROWTH: float = 0.3
## Letters with an accent in Latin-1 ([code]a→á e→é i→í o→ó u→ú y→ý n→ñ c→ç[/code] and capitals).
const PSEUDO_MAP: Dictionary = {
	"a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "n": "ñ", "c": "ç",
	"A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú", "Y": "Ý", "N": "Ñ", "C": "Ç",
}
## Formatting entries that are used inside numbers and are never pseudolocalized.
const THOUSANDS_CTX: StringName = &"thousands_separator"
const DECIMAL_CTX: StringName = &"decimal_separator"
const NUMBER_CTX: StringName = &"number"
const DURATION_CTX: StringName = &"duration"

const _PLACEHOLDER_PATTERN: String = "\\{([A-Za-z_][A-Za-z0-9_]*)\\}"
# Everything pseudolocalization keeps as it is: {name}, %% and %d/%s/%.2f, BBCode tags and line breaks.
const _PROTECTED_PATTERN: String = "\\{[A-Za-z_][A-Za-z0-9_]*\\}|%%|%[-+ #0]*\\d*(?:\\.\\d+)?[sdfxXcoeEgG]"\
		+ "|\\[/?[A-Za-z][A-Za-z0-9_]*(?:[= ][^\\]]*)?\\]|\\n"

static var _installed: bool = false
static var _catalogs: Dictionary = {}
static var _forced: String = ""
static var _setting: String = "auto"
static var _applied_language: String = ""
static var _applied_pseudo: bool = false
static var _flush_queued: bool = false
static var _strict: bool = false
static var _misses: PackedStringArray = PackedStringArray()
static var _miss_keys: Dictionary = {}
static var _drawn: PackedStringArray = PackedStringArray()
static var _placeholder_regex: RegEx = null
static var _protected_regex: RegEx = null


# --- Language ---------------------------------------------------------------------------------

## Forces [param code] ([code]en[/code], [code]es[/code] or [code]pseudo[/code]) for this run; an empty or
## unknown code lifts it. Applies at once. While a language is forced the saved setting is kept but not
## applied.
static func force(code: String) -> void:
	_ensure()
	_forced = code if FORCEABLE.has(code) else ""
	flush()


## The language forced for this run ([code]""[/code] if none).
static func forced() -> String:
	_ensure()
	return _forced


## Applies the saved setting ([param code]: [code]auto[/code], [code]en[/code] or [code]es[/code]; anything
## else counts as [code]auto[/code]). It is deferred to the end of the frame, unless a language is forced
## (then nothing changes).
static func set_language(code: String) -> void:
	_ensure()
	_setting = code if SETTING_VALUES.has(code) else "auto"
	_queue_flush()


## Applies the language in use right now: refreshes the bound nodes and notifies the tree if the language or
## the pseudolocalization changed. [method force] calls it; so do the tests after [method set_language].
static func flush() -> void:
	_ensure()
	_flush_queued = false
	var language_now: String = language()
	var pseudo_now: bool = is_pseudo()
	var state_changed: bool = language_now != _applied_language or pseudo_now != _applied_pseudo
	var locale_changed: bool = TranslationServer.get_locale() != language_now
	if not state_changed and not locale_changed:
		return
	_applied_language = language_now
	_applied_pseudo = pseudo_now
	_refresh_bound()
	if locale_changed:
		# The engine notifies the nodes of the tree on its own.
		TranslationServer.set_locale(language_now)
	else:
		var tree: SceneTree = _tree()
		if tree != null:
			tree.root.propagate_notification(Node.NOTIFICATION_TRANSLATION_CHANGED)


## The language in use: [code]en[/code] or [code]es[/code].
static func language() -> String:
	_ensure()
	if _forced == "pseudo":
		return "en"
	if not _forced.is_empty():
		return _forced
	match _setting:
		"en", "es":
			return _setting
	if AUTO_FOLLOWS_OS:
		var system: String = OS.get_locale_language()
		return system if LANGUAGES.has(system) else "en"
	return AUTO_LANGUAGE


## true while pseudolocalization is on ([code]--locale=pseudo[/code]).
static func is_pseudo() -> bool:
	_ensure()
	return _forced == "pseudo"


# --- Lookup -----------------------------------------------------------------------------------

## Translation of [param msgid] in the language in use. [param ctx] tells apart words that English
## merges ("Off" for shadows and for vsync).
static func t(msgid: String, ctx: StringName = &"") -> String:
	return _decorate(_lookup(msgid, ctx))


## Plural: [param msgid] when [param n] is 1 and [param plural] otherwise in English; the catalog's plural
## rule in other languages.
static func tn(msgid: String, plural: String, n: int, ctx: StringName = &"") -> String:
	return _decorate(_lookup_plural(msgid, plural, n, ctx))


## Translation with named placeholders ([code]{name}[/code]) filled from [param params], in a single pass: a
## value that itself contains [code]{name}[/code] is never expanded again.
static func tf(msgid: String, params: Dictionary, ctx: StringName = &"") -> String:
	return _substitute(_decorate(_lookup(msgid, ctx)), params)


## [method tn] and [method tf] together.
static func tfn(msgid: String, plural: String, n: int, params: Dictionary,
		ctx: StringName = &"") -> String:
	return _substitute(_decorate(_lookup_plural(msgid, plural, n, ctx)), params)


## Returns [param msgid] unchanged. Marks a string kept in a table that is translated when it is shown (the
## caller keeps the context too).
static func mark(msgid: String, _ctx: StringName = &"") -> String:
	return msgid


# --- Live text --------------------------------------------------------------------------------

## Sets [param property] of [param node] (the [code]text[/code] by default) to the translation of
## [param msgid] and again on every language change, also when the node comes back into the tree after
## being outside it during a switch (a pooled label, a closed window). A node is either bound or set by
## code, never both: code that later changes the text calls [method bind] again or [method unbind].
static func bind(node: Object, msgid: String, ctx: StringName = &"", property: StringName = &"text") -> void:
	_ensure()
	if node == null:
		return
	var binds: Dictionary = node.get_meta(_BINDS_META, {})
	binds[property] = [msgid, ctx]
	node.set_meta(_BINDS_META, binds)
	_apply_bind(node, property, msgid, ctx)
	if node is Node:
		var as_node: Node = node as Node
		as_node.add_to_group(BOUND_GROUP)
		if not as_node.has_meta(_HOOKED_META):
			as_node.set_meta(_HOOKED_META, true)
			as_node.tree_entered.connect(_reapply.bind(as_node))


## Stops refreshing [param node] (its text is now set by code).
static func unbind(node: Object) -> void:
	if node == null:
		return
	if node.has_meta(_BINDS_META):
		node.remove_meta(_BINDS_META)
	if node is Node:
		(node as Node).remove_from_group(BOUND_GROUP)


## Binds the texts that come from a scene ([code]text[/code], [code]placeholder_text[/code] and
## [code]tooltip_text[/code] of the standard controls): their value is the [code]msgid[/code]. A node with
## the metadata [code]l10n_raw[/code] is skipped; [code]l10n_ctx[/code] gives a context.
static func bind_scene(root: Node) -> void:
	_bind_scene_node(root)


## Marks [param node] as holding text written by a player or by staff: never translated, and the screen
## tests skip it. Call it before assigning the text.
static func raw(node: Object) -> void:
	if node != null:
		node.set_meta(RAW_META, true)


# --- Strict mode and drawn text ---------------------------------------------------------------

## Turns strict mode on or off (see the class description). Off also stops recording drawn text.
static func set_strict(on: bool) -> void:
	_ensure()
	_strict = on


static func is_strict() -> bool:
	return _strict


## The misses recorded in strict mode since the last call, as [code]ctx␟msgid[/code] lines; clears them.
static func take_misses() -> PackedStringArray:
	var result: PackedStringArray = _misses
	_misses = PackedStringArray()
	_miss_keys.clear()
	return result


## Records a string that [code]UIFonts.draw_text[/code] drew (only in strict mode, for the screen tests).
static func note_drawn(_canvas_item: CanvasItem, text: String) -> void:
	if _strict and not _drawn.has(text):
		_drawn.append(text)


## The drawn strings recorded since the last call; clears them.
static func take_drawn() -> PackedStringArray:
	var result: PackedStringArray = _drawn
	_drawn = PackedStringArray()
	return result


## Test hook: replaces the Spanish catalog (and the domain's) with [param translation]; [code]null[/code]
## puts the real one back.
static func use_spanish_catalog(translation: Translation) -> void:
	_ensure()
	_clear_domain()
	_catalogs.clear()
	var catalog: Translation = translation if translation != null else _load_spanish()
	if catalog != null:
		_catalogs["es"] = catalog
		_domain().add_translation(catalog)


# --- Numbers and units ------------------------------------------------------------------------

## [param value] with the thousands separator of the language ("12,500" or "12.500").
static func format_int(value: int) -> String:
	return _decorate(_group_thousands(value))


## [param value] with [param decimals] decimals and the decimal separator of the language ("1.25" or "1,25").
static func format_decimal(value: float, decimals: int = 2) -> String:
	return _decorate(_decimal_text(value, decimals))


## [param ratio] as a percentage (0.75 gives "75%" or "75 %").
static func format_percent(ratio: float) -> String:
	var template: String = _decorate(_lookup("{value}%", NUMBER_CTX))
	return _substitute(template, {"value": _group_thousands(roundi(ratio * 100.0))})


## A multiplier ("x1.25" or "x1,25").
static func format_multiplier(value: float) -> String:
	return _substitute(_decorate(_lookup("x{value}", NUMBER_CTX)), {"value": _decimal_text(value, 2)})


## [param value] followed by a unit entry of context [code]number[/code] (for example [code]"{value} m"[/code]
## or [code]"{value}°"[/code]). [param value] is already formatted.
static func format_unit(msgid: String, value: String) -> String:
	return _substitute(_decorate(_lookup(msgid, NUMBER_CTX)), {"value": value})


## [param seconds] as "45 s", "5 min" or "2 h 10 min" (the same abbreviations in both languages).
static func format_duration(seconds: float) -> String:
	var total: int = maxi(0, roundi(seconds))
	var hours: int = total / 3600
	var minutes: int = (total % 3600) / 60
	var secs: int = total % 60
	if hours > 0:
		if minutes == 0:
			return tf("{hours} h", {"hours": hours}, DURATION_CTX)
		return tf("{hours} h {minutes} min", {"hours": hours, "minutes": minutes}, DURATION_CTX)
	if minutes > 0:
		return tf("{minutes} min", {"minutes": minutes}, DURATION_CTX)
	return tf("{seconds} s", {"seconds": secs}, DURATION_CTX)


## [param text] between the quotation marks of the language (“…” or «…»).
static func quote(text: String) -> String:
	return tf("“{text}”", {"text": text}, &"quote")


## [param text] safe to put in a [RichTextLabel] with BBCode: its brackets cannot open tags.
static func escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


# --- Internals --------------------------------------------------------------------------------

static func _group_thousands(value: int) -> String:
	var digits: String = str(absi(value))
	var separator: String = _lookup(",", THOUSANDS_CTX)
	var out: String = ""
	var count: int = 0
	for i: int in range(digits.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			out = separator + out
		out = digits[i] + out
		count += 1
	return ("-" + out) if value < 0 else out


static func _decimal_text(value: float, decimals: int) -> String:
	var text: String = ("%." + str(maxi(decimals, 0)) + "f") % value
	return text.replace(".", _lookup(".", DECIMAL_CTX))


static func _ensure() -> void:
	if _installed:
		return
	_installed = true
	_placeholder_regex = RegEx.create_from_string(_PLACEHOLDER_PATTERN)
	_protected_regex = RegEx.create_from_string(_PROTECTED_PATTERN)
	var spanish: Translation = _load_spanish()
	if spanish != null:
		_catalogs["es"] = spanish
		_domain().add_translation(spanish)
	for arg: String in OS.get_cmdline_user_args():
		if arg == STRICT_ARG and OS.is_debug_build():
			_strict = true
		elif arg.begins_with(LOCALE_ARG_PREFIX):
			var code: String = arg.trim_prefix(LOCALE_ARG_PREFIX).strip_edges().to_lower()
			if FORCEABLE.has(code):
				_forced = code
			else:
				push_warning("[L10n] Idioma desconocido en --locale: '%s' (hay: %s)" % [
						code, ", ".join(FORCEABLE)])


static func _load_spanish() -> Translation:
	var translation: Translation = load(SPANISH_PATH) as Translation
	if translation == null:
		push_error("[L10n] No se pudo cargar el catálogo %s" % SPANISH_PATH)
	return translation


static func _domain() -> TranslationDomain:
	return TranslationServer.get_or_add_domain(DOMAIN)


static func _clear_domain() -> void:
	if TranslationServer.has_domain(DOMAIN):
		TranslationServer.remove_domain(DOMAIN)


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func _queue_flush() -> void:
	if _flush_queued:
		return
	_flush_queued = true
	L10n.flush.call_deferred()


static func _lookup(msgid: String, ctx: StringName) -> String:
	_ensure()
	if msgid.is_empty():
		return msgid
	if _strict:
		_check_strict(msgid, ctx, "")
	var catalog: Translation = _catalogs.get(language()) as Translation
	if catalog == null:
		return msgid
	var found: String = catalog.get_message(msgid, ctx)
	return found if not found.is_empty() else msgid


static func _lookup_plural(msgid: String, plural: String, n: int, ctx: StringName) -> String:
	_ensure()
	if _strict:
		_check_strict(msgid, ctx, plural)
	var catalog: Translation = _catalogs.get(language()) as Translation
	if catalog != null:
		var found: String = catalog.get_plural_message(msgid, plural, n, ctx)
		if not found.is_empty():
			return found
	return msgid if n == 1 else plural


# Records a lookup whose pair (context, msgid) has no usable Spanish entry.
static func _check_strict(msgid: String, ctx: StringName, plural: String) -> void:
	var spanish: Translation = _catalogs.get("es") as Translation
	var found: String = ""
	if spanish != null:
		if plural.is_empty():
			found = spanish.get_message(msgid, ctx)
		else:
			found = spanish.get_plural_message(msgid, plural, 1, ctx)
	if not found.is_empty():
		return
	var key: String = "%s␟%s" % [ctx, msgid]
	if _miss_keys.has(key):
		return
	_miss_keys[key] = true
	_misses.append(key)
	push_error("[L10n] Sin traducción al español: \"%s\" (contexto \"%s\")" % [msgid, ctx])


# Pseudolocalization when it is on; the text as it is otherwise.
static func _decorate(text: String) -> String:
	if not is_pseudo():
		return text
	return pseudolocalize(text)


## Pseudolocalizes [param text]: accents its literal parts, grows it by 30 % with [code]~[/code] and wraps
## it in [code]¦…¦[/code]; placeholders, BBCode tags and line breaks are kept. An empty text stays empty.
static func pseudolocalize(text: String) -> String:
	_ensure()
	if text.is_empty():
		return text
	var out: String = ""
	var literal_chars: int = 0
	var cursor: int = 0
	for found: RegExMatch in _protected_regex.search_all(text):
		var literal: String = text.substr(cursor, found.get_start() - cursor)
		out += _accent(literal)
		literal_chars += literal.length()
		out += found.get_string()
		cursor = found.get_end()
	var tail: String = text.substr(cursor)
	out += _accent(tail)
	literal_chars += tail.length()
	var fill: int = ceili(float(literal_chars) * PSEUDO_GROWTH)
	return PSEUDO_OPEN + out + PSEUDO_FILL.repeat(fill) + PSEUDO_CLOSE


static func _accent(text: String) -> String:
	var out: String = ""
	for i: int in text.length():
		var letter: String = text[i]
		out += String(PSEUDO_MAP.get(letter, letter))
	return out


# Replaces {name} placeholders in a single pass.
static func _substitute(text: String, params: Dictionary) -> String:
	if params.is_empty() or not text.contains("{"):
		return text
	var out: String = ""
	var cursor: int = 0
	for found: RegExMatch in _placeholder_regex.search_all(text):
		var key: String = found.get_string(1)
		out += text.substr(cursor, found.get_start() - cursor)
		if params.has(key):
			out += str(params[key])
		elif params.has(StringName(key)):
			out += str(params[StringName(key)])
		else:
			out += found.get_string()
		cursor = found.get_end()
	return out + text.substr(cursor)


# --- Binding ----------------------------------------------------------------------------------

static func _apply_bind(node: Object, property: StringName, msgid: String, ctx: StringName) -> void:
	node.set(property, t(msgid, ctx))


static func _reapply(node: Node) -> void:
	if not is_instance_valid(node) or not node.has_meta(_BINDS_META):
		return
	var binds: Dictionary = node.get_meta(_BINDS_META)
	for property: StringName in binds:
		var entry: Array = binds[property]
		_apply_bind(node, property, String(entry[0]), StringName(entry[1]))


static func _refresh_bound() -> void:
	var tree: SceneTree = _tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(BOUND_GROUP):
		_reapply(node)


const _SCENE_TEXT_PROPERTIES: Dictionary = {
	"Label": ["text", "tooltip_text"],
	"Button": ["text", "tooltip_text"],
	"LineEdit": ["placeholder_text", "tooltip_text"],
	"RichTextLabel": ["text", "tooltip_text"],
}


static func _bind_scene_node(node: Node) -> void:
	if node.has_meta(RAW_META):
		return
	var ctx: StringName = StringName(node.get_meta(&"l10n_ctx", ""))
	for base: String in _SCENE_TEXT_PROPERTIES:
		if node.is_class(base):
			var binds: Dictionary = node.get_meta(_BINDS_META, {})
			for property: String in _SCENE_TEXT_PROPERTIES[base]:
				var value: String = String(node.get(property))
				if not value.is_empty() and not binds.has(StringName(property)):
					bind(node, value, ctx, StringName(property))
			break
	for child: Node in node.get_children():
		_bind_scene_node(child)
