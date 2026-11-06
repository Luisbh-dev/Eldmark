# Localization: English and Spanish

How Eldmark's interface gets an English version while keeping Spanish, in small increments that can each be merged, tested and captured on their own.

In the backlog, UI-04 is the umbrella item and absorbs TEC-53. The increments are:

| Group | Increments |
|---|---|
| L1 base and tools | UI-57 (L1a), TEC-55 (L1b), TEC-56 (L1c) |
| L2 front end | UI-58 (L2a), UI-59 (L2b), UI-60 (L2c) |
| L3 combat HUD | UI-61 (L3a), UI-62 (L3b) |
| L4 server messages | TEC-57 (L4a), TEC-58 (L4b), TEC-59 (L4c), TEC-60 (L4d) |
| L5 chat, social and war | UI-63 (L5a), UI-64 (L5b) |
| L6 items, NPCs and map | UI-65 (L6a), UI-66 (L6b) |
| L7 platform | TEC-61 (L7a), TEC-62 (L7b) |
| L8 developer text | TEC-63 (L8a), TEC-64 (L8b) |
| Final review | UI-39 |

The work started once the quality waves 2–5 were merged into `main`, their files were translated (TEC-51) and the repository was public (TEC-54). The plan counts on the new HUD, the map, the fonts (`UIFonts`) and the bench comparison scripts, all of which are on `main`.

Related documents:
- [networking.md](networking.md): protocol.
- [platform.md](platform.md): accounts, e-mails, legal texts and deployment.
- [social.md](social.md): chat and commands.
- [architecture.md](architecture.md): layering.
- [tools/i18n/README.md](../tools/i18n/README.md): the comment translation tools this plan builds on.

## 0. Key decisions

| Topic | Decision | Section |
|---|---|---|
| Format | gettext: `locale/eldmark.pot` (template) and `locale/es.po`. No CSV and no keys. | 2.1 |
| Source text | The `msgid` is the English text. `es.po` holds today's Spanish texts verbatim. There is no `en.po`: the template is the English catalog. | 2.2 |
| Context, plurals and placeholders | `msgctxt` for ambiguous short strings and for each content type. gettext plurals. Named placeholders. Formatted text is never stored. | 2.3–2.5 |
| Runtime | The Spanish catalog is a `Translation` held by `L10n`, which resolves every lookup straight against it (`Translation.get_message`), and it is also added to a private `TranslationDomain` (`eldmark`) so that it is never in the main domain. The main domain stays empty, so the engine never translates a node by itself, and `L10n` is the only way text gets translated. | 4.1–4.2 |
| Pseudolocalization | Implemented in `L10n`. The engine's pseudolocalization is never used: in 4.7.2 it breaks `{name}` and BBCode, skips plurals and uses glyphs our fonts lack. | 4.5 |
| Default language | The `language` setting is `auto` by default. Until the final review (UI-39), `auto` means Spanish, so nobody sees a half-translated game without asking for it. From UI-39 on, `auto` follows the OS language, with English for languages that have no catalog. | 4.3 |
| Selector | "Language" in the Interface tab: Automatic, English or Español. Saved, applied before the first screen and switched live, also from the selector itself. "Restore all" does not touch it. `--locale=` forces a language for one run and is not saved. | 4.3–4.4 |
| Layering | `scripts/shared`, `scripts/world` and `scripts/server` never produce text for players. They return codes and parameters, and the client turns them into text. | 6 |
| Server messages | NOTICE, REJECT details and system chat travel as a message id plus typed parameters (protocol 8). A transitional `legacy.text` id lets the wire format land first and the senders move area by area. | 7 |
| Content data | `display_name`, `description` and `label` in `.tres` files hold the English text; the Spanish lives in `es.po`, with one context per type. No duplicated resources and no remaps. | 8.1 |
| Phase 6-8 content text | Quests, lore, events, dialogues, talents, specializations, affixes, professions and NPC text use one context per field and the `msgid` in English. A sentence is never built around a noun placeholder, and descriptions and dialogues carry a translator note. Message ids 600-849 and parameter kinds 8-12 are reserved for them | 7.1, 7.2, 8.1 |
| Proper names | Descriptive names are translated (Puente del Norte → North Bridge, los Huecos → the Hollow). Invented names stay as they are (Vado Gris, Eldrun, Vardheim...). | 8.2 |
| Chat commands | Canonical English ids. The long names work in both languages; the short aliases follow the client's language. | 9 |
| Legal texts | Spanish is binding. The English version is a translation and says so. | L7b |
| Not translated | Logs, debug overlays, staff and console replies and tool output are English only (L8). Player names, chat, moderator reasons and operator messages are shown as written. | 1.2 |
| Tests | Always in English, whatever the machine or its `settings.cfg`. A strict mode fails any lookup with no Spanish entry. A Spanish snapshot of each migrated screen proves the Spanish did not change. A pseudo test proves the screen refreshes. | 11–12 |
| Increments | Twenty small ones plus the final review, each ending with the same screens captured in English and in Spanish. | 13–14 |

English `msgid`s replace the earlier backlog recommendation of Spanish `msgid`s, because the code, comments and docs are now in English, contributors read English in the code, and English is what a player should see when their language has no translation.

## 1. Starting point

### 1.1 What there is today

With the waves merged, there is still no localization at all:
- no `tr()`, `atr()` or `TranslationServer` call;
- no `.po` or `.csv` file and no `[internationalization]` section in `project.godot`;
- no language setting.

Every visible text is a Spanish literal, and most of the UI is built in code (`make_label()`, `.text =`, `const` tables and `draw_string`). Only three scenes carry text: `scenes/ui/realm_select.tscn` (12 texts), `hud.tscn` ("FPS: 0", a debug overlay) and `net_debug_overlay.tscn` ("RED", debug).

Survey (approximate, ±20 %):

| Surface | Strings | Notes |
|---|---|---|
| `scripts/client` | 600–700 | Front end ~200, settings ~70, combat HUD ~130, map ~25, war HUD ~55, inventory ~60, chat ~55 |
| Text drawn with `draw_string` | 13 client files | minimap, world map, nameplate, party frame, status icons, icon slot, key glyph, vitals, compass, objective line, world markers, fraction bar, placeholder icon |
| `scripts/shared` producing UI text | ~100 | `NetProtocol.result_text` and `realm_display_name`, `WarEvents`, `NameRules`, `InventoryOps`, `RealmCatalog`, `Currency`, `ChatText` |
| Content data | ~55 fields | 49 `display_name`/`description` fields in `data/`, 5 landmark labels in `assets/maps/vado_gris_map.tres`, plus `CombatText` and `zone_places.gd` in code |
| Text the server sends to players | ~215 | NOTICE, REJECT and system chat (party, moderation, chat router, progress, `/unstuck`), plus ~50 replies only staff see |
| Platform (Go) | ~280 | API error messages (which already carry codes), e-mails, legal texts, web pages |
| Tests that compare Spanish text | ~480 assertions in 83 files | plus ~60 that read Spanish log lines |

Some pieces are already a good start: `HintCatalog` uses named placeholders, `WarEvents` travels as an id, platform errors carry a stable `code`, and `InventoryOps` results and `NameRules` reasons travel as codes.

### 1.2 What is not localized

- **Text written by players:** character names, chat, whispers and report comments. Never translated. The nodes that show it are marked raw (5.1).
- **Text written by staff:** moderator reasons, the platform's maintenance message, `/broadcast` and kick reasons. Shown as written, inside a translated sentence ("Maintenance in 5 min: {message}").
- **Text for developers and operators:** logs, `push_error`/`push_warning`, catalog validation errors, the F3 network panel, the FPS and DPS overlays, GM and console replies, the galleries in `scripts/client/tools` and tool output. English only, never in the template (L8).

## 2. Format and source language

### 2.1 gettext rather than CSV

- PO is the format translators and their tools already know (Poedit, Weblate, Crowdin), so an open source project can take community translations without custom tooling.
- Each string is one entry, with translator comments (`#.`), references (`#:`), context (`msgctxt`) and plural forms. Godot loads `.po` files at runtime with `load()`, with no import step (checked in 4.7.2).
- Diffs and merges work line by line, and adding a language adds one file.
- CSV needs an import step and has no translator comments or references.
- We generate the template ourselves (10.1), so we do not depend on the editor's template generator.

### 2.2 English `msgid`s rather than keys

- `L10n.t("Restore tab")` reads naturally, and a missing translation shows correct English.
- `es.po` maps each English `msgid` to the exact Spanish the game shows today, so Spanish players see no change when an area is migrated. The Spanish snapshots (12.2) prove it.
- Keys (`UI_SETTINGS_RESTORE_TAB`) would need an `en.po`, make the code harder to read and show a raw key when a translation is missing.
- **Cost:** fixing a typo in an English `msgid` invalidates its Spanish entry. `l10n_po.py --check` reports it, and the fix and its `es.po` update go in the same commit.
- **English cannot be untranslated**, because the template is the English catalog. The check for English is that no `msgid` looks Spanish (accents, `¿`, `¡`, Spanish function words), with an allowlist for the invented names of 8.2.

### 2.3 Context (`msgctxt`)

English merges distinctions that Spanish keeps: "Off" is "Desactivadas" for shadows but "Desactivada" for vsync; "Light" is "Clara" for skin but "Ligero" for an attack.

- Single words, adjectives and very short strings carry a context that says where they appear or what they describe: `L10n.t("Off", &"shadows")`.
- Content data uses one context per type: `item`, `item_desc`, `race`, `race_desc`, `npc`, `fort`, `place`, `realm`, `ability`, `ability_desc`, `status`, `cause` (a noun phrase used inside a death sentence), `appearance_hair`, `appearance_skin` and so on (8.1).
- Formatting entries use the contexts `thousands_separator`, `decimal_separator`, `number`, `duration`, `date` and `key` (4.7).
- The migration tool refuses two different Spanish texts that would end up with the same `msgid` and context. One of them needs a context first.

### 2.4 Plurals

- `L10n.tn(singular, plural, n)` and `L10n.tfn(...)`. With no translation (English), the singular is used when `n == 1` and the plural otherwise (checked).
- The `es.po` header has `Plural-Forms: nplurals=2; plural=(n != 1);`.
- Durations use abbreviations that need no plural in either language (`30 s`, `5 min`, `2 h`), through `L10n.format_duration`.
- Plurals are for counted nouns only ("{count} days", "+{count} more"). Never build a plural with `"s" if n != 1 else ""`.

### 2.5 Placeholders and formatted text

- **Two or more values:** named placeholders, `L10n.tf("Free slots: {free} of {total}", {"free": free, "total": total})`, so a translation can reorder them.
- **One value:** `%d` and `%s` are allowed (`L10n.t("%d FPS") % limit`). The mechanical migration keeps them.
- **Formatted text is never stored.** `"Volumen: %s" % name` or `"%d FPS" % limit` kept in a table (today in the static settings schema) cannot be translated later and does not follow a language change. Tables store the `msgid`, its context and the parameters, and the text is composed when it is shown.
- `l10n_po.py --check` fails when a translation does not use exactly the same placeholders (`{name}`, `%s`, `%d`, `%%`) and BBCode tags as its `msgid`.
- `L10n.tf` replaces placeholders in a single pass, so a parameter value that itself contains `{name}`, such as a moderator reason, is never expanded a second time.

### 2.6 Translator comments and escapes

- A `# TRANSLATORS: ...` comment on the line above an `L10n` call or a marked `const` becomes a `#.` comment in the template. Use it when the screen or the length limit is not obvious ("button, max ~14 characters").
- Godot's PO parser decodes `\n`, `\t`, `\"` and `\\`, but not `\uXXXX` (checked in 4.7.2). The extractor decodes GDScript escapes exactly as GDScript does and writes every other character as UTF-8, never as `\u`. `tests/test_l10n_catalog.gd` loads the template through Godot and fails on any entry that Godot reads differently from the extractor.

## 3. Files, project settings and export

```
locale/
  eldmark.pot   # template, generated by tools/i18n/l10n_extract.py, versioned (from L1b)
  es.po         # Spanish, edited by hand or with Poedit, versioned (from L1a)
```

- **Deterministic output:** entries sorted by the file of their first reference, then by context and `msgid`; references give the file but **no line numbers** (`#: scripts/client/ui/settings_menu.gd`), so moving code does not churn the template; no creation date in the header.

```po
#. TRANSLATORS: button that resets only the settings of the open tab.
#: scripts/client/ui/settings_menu.gd
msgid "Restore tab"
msgstr "Restaurar pestaña"
```

- `project.godot` gets only:

```ini
[internationalization]
locale/fallback="en"
rendering/root_node_auto_translate=false
```

  No `pseudolocalization/*` keys, and the translations are **not** listed in `internationalization/locale/translations`: the client loads them into its private domain (4.2), so the dedicated server never loads them.
- **Export:**
  - the client preset adds `locale/*.po` to its `include_filter`, so the catalog is exported whatever `all_resources` decides;
  - the server preset adds `locale/*` to its `exclude_filter`. It is a one-line change, and the server never needs the catalog;
  - `tests/test_export_config.gd` checks both filters.
- Text files only (CLAUDE.md): `.po` and `.pot`. No `.mo` and no imported `.translation`.

## 4. Runtime

### 4.1 What Godot 4.7.2 does (checked headless)

These facts were checked with headless spikes on 4.7.2. `tests/test_l10n_runtime.gd` (L1a) keeps them as regression tests, so an engine upgrade that changes them fails the suite.

| Fact | Consequence |
|---|---|
| `load("res://locale/es.po")` works at runtime with no import. Context, plurals and fuzzy entries (ignored) behave as in gettext. | No import step and no `.translation` files. |
| A translation added to the **main** domain is applied automatically to **orphan** nodes even with `root_node_auto_translate=false`: an orphan `Label` with "Restore tab" showed the Spanish text and lost it when it entered the tree. | The catalog goes into a private domain instead. |
| A translation in a private domain (`TranslationServer.get_or_add_domain(&"eldmark")`) translates with context and plurals, follows `TranslationServer.set_locale` (`es_ES` and `es_MX` use `es`, `fr_FR` gets the `msgid`), and no node, orphan or not, is translated automatically. | `L10n` is the only path. `tr()` would not see our catalog, so it is banned (6). |
| `Translation.get_message(msgid, ctx)` returns an empty string for a missing entry, an empty `msgstr` and a fuzzy entry, and the translated text otherwise (also when it equals the `msgid`, as with "Audio"). The same holds for `get_plural_message`. | Strict mode (4.6). |
| `OS.get_locale()` returns `"es"` on a Spanish Windows, not `"es_ES"`. | Use `OS.get_locale_language()`. |
| `TranslationServer.set_locale` sends `NOTIFICATION_TRANSLATION_CHANGED` synchronously to the nodes in the tree, and only when the locale string changes (`en` → `en_US` notifies; `es` → `es` does not). It also notifies when the main domain is empty. | `L10n.set_language` propagates the notification itself when the locale string stays the same (pseudo on and off, `auto` resolving to the current language). |
| `get_nodes_in_group` only returns nodes in the tree. | Bound nodes outside the tree (pools, closed windows) reapply their text when they enter it (4.4). |
| The engine's pseudolocalization turns "Free slots: {free} of {total}" into a text whose placeholders carry accents (`{f́ŕéé}`), so `format()` no longer replaces them; it breaks BBCode tags (`[ḅ]`); it leaves plurals untouched; `skip_placeholders` only protects `%` markers; and it uses characters (ḅ, ṕ, Ŝ, Ĥ, ŧ, a combining accent) that Cinzel and IM Fell English lack. | Own pseudolocalization (4.5). |
| `_draw` runs in headless mode after `queue_redraw()`, with no window. | The screen tests can record the strings drawn with `UIFonts.draw_text` (`note_drawn`). |
| `CanvasItem._draw` runs in headless mode after `queue_redraw()`. | Drawn text can be checked by the screen test (4.4). |
| Godot's PO parser does not decode `\uXXXX`. | Extractor rule (2.6). |

### 4.2 The `L10n` API (`scripts/client/l10n/l10n.gd`, client only)

`L10n` is a static class. It installs itself on first use: it loads `res://locale/es.po` into the `eldmark` domain and reads `--locale=` from the user arguments. Every entry point works without `ClientServices`, so the galleries and previews (`scenes/tests/ui_gallery.tscn`, `chat_preview.tscn`) and the tests get the same behaviour as the game.

| Function | Use |
|---|---|
| `force(code)` | Forces `"en"`, `"es"` or `"pseudo"` (pseudolocalized English) for this run; `""` lifts it. Set by `--locale=` and by the test runner. While a language is forced, the saved setting is kept but not applied. |
| `set_language(code)` | Called by `ClientSettings` with the setting: `"auto"`, `"en"` or `"es"`. Applies it (deferred) unless a language is forced. |
| `language() -> String` | The language in use: `"en"` or `"es"`. |
| `is_pseudo() -> bool` | Whether pseudolocalization is on. |
| `t(msgid, ctx = &"")` | Translation. |
| `tn(msgid, plural, n, ctx = &"")` | Plural. |
| `tf(msgid, params, ctx = &"")` / `tfn(msgid, plural, n, params, ctx = &"")` | Translation plus named placeholders, in a single pass. |
| `mark(msgid, ctx = &"")` | Returns `msgid` unchanged. Marks a string stored in a table and translated when shown (the caller stores the context too). |
| `bind(node, msgid, ctx = &"", property = &"text")` | Sets the translated text now and again on every language change, also when the node re-enters the tree. |
| `unbind(node)` | Stops refreshing a node whose text is now set by code. |
| `bind_scene(root)` | Binds the texts that come from a `.tscn` (their value is the `msgid`). |
| `raw(node)` | Marks a node whose text comes from a player or from staff. Never translated; the screen test skips it. |
| `note_drawn(canvas_item, text)` | Called by `UIFonts.draw_text` for every drawn string. Records it in test mode; does nothing otherwise. |
| `set_strict(on)`, `take_misses() -> PackedStringArray` | Strict mode (4.6). |
| `forced() -> String` | The language forced for this run (`""` if none). |
| `flush()` | Applies the language in use right now (refreshes the bound nodes, notifies the tree). `force` calls it; the tests call it after `set_language`, which is deferred. |
| `pseudolocalize(text) -> String` | The own pseudolocalization (4.5), exposed for tests. |
| `take_drawn() -> PackedStringArray` | The strings recorded by `note_drawn` since the last call; clears them. |
| `use_spanish_catalog(translation)` | Test hook: replaces the Spanish catalog; `null` puts the real one back. |
| `format_int`, `format_decimal`, `format_percent`, `format_multiplier`, `format_unit`, `format_duration` | Numbers and units (4.7). `format_date` and `format_datetime` are not there yet: they arrive in L2a. |
| `quote(text)`, `escape_bbcode(text)` | Quotation marks for the language («» or “”), and safe parameters for a `RichTextLabel`. |

### 4.3 Choosing the language

1. A forced language wins: `--locale=<code>` on the client command line (after `--`), or the test runner. It accepts `en`, `es` and `pseudo` and is never saved. `boot.gd` lists `--locale=` and `--l10n-strict` among the arguments the sandbox accepts, so it does not warn "Argumento desconocido".
2. Otherwise the `language` setting decides (`[interface] language` in `user://settings.cfg`): `auto` (the default), `en` or `es`.
3. `auto` resolves with the constant `L10n.AUTO_FOLLOWS_OS`:
   - `false` from L1a until UI-39: `auto` means Spanish. Nothing changes for anyone who does not pick English, and nobody gets a half-translated game by accident while the increments land. The option reads "Automatic (Spanish)" and English reads "English (incomplete)".
   - `true` from UI-39 on: `auto` means `OS.get_locale_language()` if it has a catalog (`es`), and English otherwise. The options read "Automatic (system)", "English" and "Español".

The setting is a `CHOICE` in `ClientSettings`, on the first row of the Interface tab. "English" and "Español" are endonyms and are not translated; the "Automatic" label is. `ClientServices` applies it before building the first screen, together with the other saved settings. The setting is marked not restorable: "Restore tab" and "Restore all" leave it alone, because a player who restores defaults into a language they cannot read may not find the way back.

### 4.4 Switching live

`set_language(code)` works out the new effective language and pseudo state; if nothing changes, it does nothing. Otherwise, deferred to the end of the frame:
1. it refreshes the bound nodes in the group `l10n_bound`;
2. it calls `TranslationServer.set_locale(code)` when the locale string changes, which notifies the tree, or else propagates `NOTIFICATION_TRANSLATION_CHANGED` from the root itself.

It is deferred because the usual caller is the selector itself: `OptionButton.item_selected` → `ClientSettings.changed` → `ClientServices.apply_value` → `set_language`. A synchronous notification would make `SettingsMenu` rewrite that same `OptionButton` while its popup is still inside its own signal.

There are four cases:

- **Fixed text:** `L10n.bind(node, "Restore tab")`.
  - A node is either bound or set by code, never both. Code that later changes the text calls `bind` again with the new `msgid`, or `unbind`.
  - `bind` also connects `tree_entered`, so a bound node that was outside the tree during a switch (a pooled label, a closed window) catches up when it comes back.
- **Text with values** ("Free slots: 2 of 3"): the owner implements `_refresh_texts()` and calls it from `_notification(NOTIFICATION_TRANSLATION_CHANGED)` once it is ready. Refreshing changes texts in place (`set_item_text`, `set_tab_title`, `label.text`); it never rebuilds controls (`clear()`, `add_item()`). Widgets that recompute their text on every update (vitals, timers, scoreboard rows) need nothing.
- **Drawn text:** every `draw_string` of the client goes through `UIFonts.draw_text(canvas_item, font, position, text, ...)`, which draws the outline and the fill and calls `L10n.note_drawn`. The text comes from `L10n` like any other. Every `CanvasItem` that draws text calls `queue_redraw()` on `NOTIFICATION_TRANSLATION_CHANGED`, after recomputing any text it caches.
- **Exceptions:**
  - Lines already printed in the chat, the kill feed and the hint log stay in the language they were written in.
  - A modal widget that cannot be open while the language changes (`UIConfirmDialog`, `SplitDialog`) translates when it opens. It is listed in `L10N_REFRESH_ON_OPEN` in the screen test, with the reason.

### 4.5 Pseudolocalization

`L10n` pseudolocalizes when the forced language is `pseudo`:

1. The real lookup happens first (English: the `msgid`), so pseudo also exercises plural selection and context.
2. Only the literal parts of the text change. `{name}`, `%s`/`%d`/`%.2f`/`%%`, BBCode tags (`[b]`, `[color=…]`, `[/url]`) and line breaks are kept as they are.
3. Letters get accents from Latin-1 only (`a→á e→é i→í o→ó u→ú y→ý n→ñ c→ç` and their capitals). All three fonts cover Latin-1 completely (checked with `Font.has_char`).
4. The text grows by 30 % with `~` and is wrapped in `¦…¦`. The `¦` marker is in Latin-1 and in the three fonts; `⟦⟧` is not, and `«»` would clash with the Spanish quotation marks of `L10n.quote`.
5. Parameters are formatted first and inserted afterwards, so player names stay readable and a number or a nested translation is wrapped on its own.
6. It applies the same way to `t`, `tn`, `tf`, `tfn`, `bind` and the `format_*` helpers, except the two separator entries (`thousands_separator`, `decimal_separator`), which are used inside numbers.

The screen test (11) uses it to prove that every visible text went through `L10n` and refreshes. The bench can capture any step in pseudo (`--locale pseudo`) to look for cut texts.

### 4.6 Strict mode

Pseudolocalization proves that a text went through `L10n`, not that it has a Spanish translation: a `msgid` missing from `es.po`, a misspelled context, a Spanish string passed to `L10n.t` or a text formatted before the lookup ("Volume: Música") all come out pseudolocalized. So:

- With `L10n.set_strict(true)`, every lookup (`t`, `tn`, `tf`, `tfn`, `bind`, the format helpers) checks that the pair (context, `msgid`) has a non-empty, non-fuzzy entry in the Spanish catalog, whatever the language in use. A miss is recorded once per entry and reported with `push_error`.
- The test runner turns strict mode on before each test and fails the test when `L10n.take_misses()` is not empty, even when the test allows logged engine errors.
- Release builds never run in strict mode: `L10n` only accepts `--l10n-strict` when `OS.is_debug_build()` is true. Debug builds can turn it on with it.

### 4.7 Numbers, dates and units

- **Separators:** translatable entries. `msgid ","` with context `thousands_separator` is `"."` in Spanish, and `msgid "."` with context `decimal_separator` is `","`.
  - `L10n.format_int(12500)` gives "12,500" or "12.500".
  - `format_decimal(1.25, 2)` gives "1.25" or "1,25". It replaces the hardcoded commas of `ClientSettings.format_value` ("x1,25") and `UIIconSlot` (cooldowns).
- **Percent:** `format_percent(0.75)` uses `{value}%` (context `number`), which Spanish writes `{value} %`. The multiplier uses `x{value}`.
- **Durations:** `format_duration(seconds)` gives "45 s", "5 min" or "2 h 10 min" (context `duration`).
- **Dates:** the pattern is an entry with the context `date`, always in the player's time zone. English uses `{year}-{month}-{day} {hour}:{minute}` and Spanish `{day}/{month}/{year} {hour}:{minute}`. It replaces `PlatformErrors.format_date` and the dates the platform used to format.
- **Yes/No and On/Off:** entries with a context, never `"Sí" if x else "No"` in code.
- `TranslationServer.format_number` only converts digit systems, so it is not used for grouping.

### 4.8 Fonts and glyphs

Noto Sans (body), Cinzel (titles) and IM Fell English SC (map) cover Latin-1 completely, plus `‹›“”‘’…·×–—`, so English and Spanish render in all three.

Some symbols are missing today, whatever the language (checked with `Font.has_char`):
- in all three: the arrows `← ↑ → ↓` (`UIKeyGlyph`), `▶ ◀` (`character_create.gd`) and `✕` (`ui_window.gd`);
- in IM Fell only: `−` (U+2212).

`tests/test_l10n_glyphs.gd` (L1a) loads the fonts through `UIFonts` and checks every character of `es.po` (and, from L1b, of the template) and the pseudolocalization alphabet. Those symbols stay on a documented allowlist until they become icons (UI-39).

Cinzel and IM Fell are small-capital faces, so English mixed case renders in small capitals and the widths change. Long strings are reviewed in the captures.

## 5. Writing translatable code

These rules are enforced on migrated files by the scan (10.3) and at runtime by the screen test (11):

1. **Store `msgid`s and translate when the text is shown.** Tables, schemas and catalogs keep the English text, marked, with its context. Translating while a table is built breaks the live switch: the static `ClientSettings` schema is built once.
2. **Never store formatted text** (2.5). Store the `msgid`, the context and the parameters.
3. **Whole sentences only.** Never `name + " derrotó a " + other`. One template with placeholders: `L10n.tf("{killer} defeated {victim} with {cause}", {...})`.
4. **No grammar in code.** Code adds no articles, genders or plural endings. Noun phrases used inside sentences are their own entries (context `cause`: "a heavy blow" → "un golpe pesado"). When a subject needs another verb form (the Hollow, plural in Spanish), use another template, not a parameter.
5. **No case changes on translated text** (`capitalize()`, `to_upper()`). Today `capture_panel.gd` capitalizes "los Huecos". Write the entry in the right case.
6. **Numbers that come from data are parameters.** "You dash 6 m" becomes `"You dash {distance} m"`, filled in from the `.tres`, so a balance change cannot leave a stale tooltip.
7. **Ids are never derived from text.** Node names, marker ids and file names stay ids:
   - `page.name = "Gráficos"`, used today as a tab title, becomes `page.name = String(tab)` plus `set_tab_title(i, L10n.t(...))`;
   - `marker_source.gd` builds `pass_<label in snake_case>` from a landmark label; it gets an id from the landmark;
   - the bench names its captures after ids, not titles (13).
8. **Player and staff text is raw.** Call `L10n.raw(label)` before assigning a name or a chat line. In a `RichTextLabel` with BBCode, parameters go through `L10n.escape_bbcode`.
9. **Icons do not depend on text.** Placeholder icons drawn from the first letter of a name use the id, not the translated name.
10. **Text is drawn with `UIFonts.draw_text`**, never with a bare `draw_string` (4.4).
11. **Every new `msgid` gets its Spanish entry in the same commit** (15).

### 5.1 How strings are marked

| Where | How |
|---|---|
| Code | `L10n.t`, `tn`, `tf`, `tfn`, `mark` or `bind`. The extractor reads the arguments by position according to each signature (10.1), context included. A non-literal argument is not extracted, which is correct for values already marked elsewhere. `tr()`, `tr_n()`, `atr()` and `atr_n()` are banned. |
| `const` (it cannot call functions) | A marker comment on the first line: `const TAB_NAMES: Dictionary = {  # l10n ctx=settings_tab`. The extractor takes every string value of the initializer, never dictionary keys. For tables of records, `fields=` names the keys that hold text: `const COMMANDS: Array[Dictionary] = [  # l10n ctx=chat_command fields=usage,help`. The code that reads it translates: `L10n.t(TAB_NAMES[tab], &"settings_tab")`. |
| `.tscn` | The `text`, `placeholder_text` and `tooltip_text` of `Label`, `Button`, `CheckBox`, `CheckButton`, `LineEdit` (placeholder only: its `text` is data) and `RichTextLabel`, in scenes listed in the scope (10.3). The scene's script calls `L10n.bind_scene(self)`. A node with `metadata/l10n_raw = true` is skipped; `metadata/l10n_ctx` gives a context. |
| `.tres` | The fields listed in 8.1, each with the context of its type, in resources listed in the scope. |
| Not interface text | A string the scan mistakes for interface text gets `# l10n-ignore: <reason>` at the end of its line. |

### 5.2 Examples

```gdscript
# Fixed text that follows the language.
L10n.bind(_restore_tab_button, "Restore tab")

# Values in a sentence.
_slots_label.text = L10n.tf("Free slots: {free} of {total}", {"free": free, "total": total})

# A counted noun.
_restore_label.text = L10n.tfn("You can restore it for {days} day.",
		"You can restore it for {days} days.", days, {"days": days})

# Same English, different Spanish.
L10n.t("Off", &"shadows")  # Desactivadas
L10n.t("Off", &"vsync")    # Desactivada

# A table that cannot call functions.
const TAB_NAMES: Dictionary = {  # l10n ctx=settings_tab
	TAB_GRAPHICS: "Graphics", TAB_AUDIO: "Audio", TAB_CAMERA: "Camera", TAB_INTERFACE: "Interface",
}

# Text that refreshes on a language change, in place.
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_texts()

# Drawn text.
UIFonts.draw_text(self, font, at, L10n.t(CARDINALS[i], &"compass"), FONT_SIZE, TEXT_COLOR, 3, TEXT_OUTLINE)

# A player name.
L10n.raw(_name_label)
_name_label.text = character_name
```

## 6. Layering: who produces text

The server loads `scripts/shared`, so shared code stays neutral about language, and `scripts/server` never translates. `tests/test_architecture.gd` gets these rules:

- `scripts/shared`, `scripts/world` and `scripts/server` do not use `TranslationServer` or `L10n` (`L10n` is a client class, already covered by the existing check that keeps client classes out of shared code).
- No script in `scripts/` calls `tr`, `tr_n`, `atr` or `atr_n`. The patterns use word boundaries (`\btr\(`, `\btr_n\(`, `\batr\(`, `\batr_n\(`) so that `str(` does not match.
- Shared code returns codes and numbers. The client has one renderer per catalog in `scripts/client/l10n/`.

| Today (shared) | After | Increment |
|---|---|---|
| `NetProtocol.result_text` (REJECT texts) | The client's `RejectText` translates by `Result`. The server keeps an English operator text for its logs and for clients that do not know a code. | L2c (client), L4b (server) |
| `NameRules.reason_text`, `rules_summary` | `NameRules` returns reason codes and limits. Text in `NameRuleText` (client). | L1b (client), L4b (server) |
| `NetProtocol.realm_display_name` "Ninguno", `RealmCatalog` names, `WarEvents.realm_label` "los Huecos" | `RealmText` (client) renders realm names (context `realm`) and picks the Hollow variant of a template. The shared functions stay for logs until L8b. | L1b (realm select), L5b (war) |
| `WarEvents._TEXTS` | The ids stay in shared code. The templates move to `WarEventText` (client), with English placeholder names (`{realm}`, `{fort}`). | L5b |
| `ChatText` reasons | Codes. Text in the client. | L5a |
| `InventoryOps.result_text`, `Currency` names | Codes and numbers. Text in `InventoryText` (client). | L6a |
| `FortressDefinition.display_name`, default "Fuerte" in `WarEvents` and `marker_source.gd` | English in the `.tres`, translated by the client (context `fort`); the default becomes a client entry. | L5b, L6b |

## 7. Server messages (protocol 8)

### 7.1 Catalog

`scripts/shared/net/server_messages.gd` (`class_name ServerMessages`) is the contract between the server and the client. It holds no text:

```gdscript
const PARTY_DECLINED: int = 201
const _DEFS: Dictionary = {
	PARTY_DECLINED: [&"party.declined", [["name", Param.NAME]]],
}
```

- Every message has a numeric id (u16) that is never reused (a removed id becomes reserved), a stable key such as `party.declined` (used by logs and tests) and a list of parameters with their names and kinds.
- Id ranges:

| Ids | Area |
|---|---|
| 1–99 | Server operation and session |
| 100–199 | Authentication details |
| 200–299 | Party |
| 300–399 | Chat and moderation |
| 400–499 | Progression and inventory |
| 500–599 | World commands (`/unstuck`) |
| 600–699 | Quests and world events ([quests.md](quests.md) section 5.2) |
| 700–749 | Build and specialization |
| 750–799 | Loot and economy services |
| 800–849 | Interaction and dialogue |
| 900–998 | Staff |
| 999 | `legacy.text {text: TEXT}`: transitional, removed in L4d |

- The English templates live in the client, in `scripts/client/l10n/server_message_text.gd` (`const TEMPLATES: Dictionary = {  # l10n ctx=server`), for example `&"party.declined": "{name} declined your invitation."`. A test checks that every catalog key has a template whose placeholders are exactly the parameter names.
- `ServerMessages.wire_hash()` covers the ids, keys and parameter kinds, not the templates. It joins `NetProtocol.compute_sim_hash`, as `ItemDatabase.wire_hash()` does, so a client with another catalog is rejected with `SIM_HASH` ("update the client"). Adding messages in L4b–L4d changes the hash, not the protocol version.

Initial examples (the full list is built in L4b–L4d):

| Id | Key | Parameters | English template |
|---|---|---|---|
| 1 | `server.shutdown_in` | seconds: SECONDS | The server will shut down in {seconds}. |
| 2 | `server.maintenance_in` | seconds: SECONDS, message: TEXT | Maintenance in {seconds}: {message} |
| 5 | `session.replaced` | — | You logged in from another place. |
| 8 | `server.broadcast` | message: TEXT | {message} |
| 102 | `auth.suspended_until` | until: TIME, reason: TEXT | Your account is suspended until {until}: {reason} |
| 201 | `party.declined` | name: NAME | {name} declined your invitation. |
| 301 | `chat.muted_for` | seconds: SECONDS | You are muted for {seconds} more. |
| 400 | `inventory.bag_full` | — | Your bag is full. |
| 502 | `unstuck.cooldown` | seconds: SECONDS | /unstuck: available again in {seconds}. |
| 900 | `staff.reply` | text: TEXT | {text} |
| 999 | `legacy.text` | text: TEXT | {text} |

### 7.2 Message block

NOTICE and REJECT share this block (`NetMessages.MessageBlock`):

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u16 | message_id | `ServerMessages` id, ≥ 1 |
| 2 | u8 | param_count | 0–4 |
| 3 | n B | params | each one: `u8 kind` + value |

| Kind | Value | Client shows |
|---|---|---|
| 1 INT | i32 | `L10n.format_int` |
| 2 NAME | u8 len + UTF-8 (the protocol's name limit) | as written, raw |
| 3 TEXT | u16 len + UTF-8 (≤ 768 B, `ChatText.MAX_BYTES`) | as written (moderator reason, operator message, staff reply), escaped |
| 4 TIME | u32 Unix seconds | `L10n.format_datetime`, in the local time zone |
| 5 SECONDS | u32 | `L10n.format_duration` |
| 6 REALM | u8 realm code | realm name |
| 7 ITEM | u16 item wire id | item name (context `item`) |
| 8 QUEST | u16 quest wire id | quest title (context `quest`) |
| 9 EVENT | u16 world event wire id | event name (context `event`) |
| 10 SPEC | u8 specialization id | specialization name (context `specialization`) |
| 11 NPC | u16 NPC definition wire id | NPC name (context `npc`) |
| 12 PLACE | u16 place wire id | zone, place, pole or pass name (context `place`) |

- Kinds 8-12 are the phase 6-8 additions: 8 and 9 come with the quest messages (600-699), 10 with the build messages
  (700-749), 11 and 12 with the interaction messages (800-849). A parameter never replaces a noun inside a sentence
  (section 8.1, "Sentences and nouns"): the title is a whole value that the client prints with its own context.
- TEXT has a u16 length because staff replies such as `inv_show` and `ledger_show` listings travel today as system chat lines of up to 768 B; 200 B would cut them.
- The whole block is at most 1024 B, within the 1200 B packet budget. `encode` trims TEXT at a UTF-8 boundary to fit.
- Each parameter carries its kind, so the decoder does not need the catalog. `decode` checks structure, sizes and UTF-8 and returns null on any error, like every other message.

### 7.3 NOTICE v8

Layout: `u8 type (0x30)`, `u8 code`, then the block. The decoder keeps the exact-size rule: the version reject already separates protocols.

| Code | Meaning |
|---|---|
| 0 INFO | Toast and system chat line |
| 1 KICK | Banner, then the server disconnects |
| 2 SHUTDOWN | Banner |
| 3 CHAT | New: system chat line only |

The free text and its 200 B limit disappear. Operator text travels as a TEXT parameter.

### 7.4 REJECT v8

Layout: `u32 magic`, `u8 result`, `u8 text_len`, the text, then an **optional block**.

- **The prefix is the v7 layout, and it is frozen forever.** A v7 client only decodes a REJECT whose size is exactly `6 + text_len`.
- **Rejects sent before the client's version is known carry no block, and their text is fixed English.** `ServerAuth.validate` answers `MALFORMED` (the HELLO did not decode) before it checks `VERSION`, so both are pre-version rejects. Any client, of any version, can read why it was turned away: "Incompatible game version: update the client".
- **The v8 decoder is tolerant after the prefix.** It validates the prefix, then reads a block if the remaining bytes hold a valid one, and ignores anything it cannot read instead of returning null. REJECT is the only message that has to be readable across versions, so a future version can extend it without the exact-size wall of v7. The fuzz tests check that a valid prefix with any tail decodes to the prefix.
- **The `Result` codes do not change.** The client translates by code (from L2c). When a block is present, it shows the more specific message instead:
  - `auth.no_ticket`;
  - `auth.character_load_failed`;
  - `auth.suspended_until`, `auth.banned` or `auth.deletion_pending`: the server forwards `until` and `reason` from the platform's 403 `Extra` instead of the sentence the platform composes;
  - `auth.name_invalid {min, max}`.
- **The text field** becomes an English operator string that the server keeps (`scripts/server/reject_texts.gd`). The client only shows it for a `Result` it does not know. The `_rejects` counter uses the `Result` name as its key.

### 7.5 System chat

- `CHAT_MESSAGE` on the `SYSTEM` channel is no longer valid on the wire; the decoder rejects it.
- `ChatRouter.send_system(peer, id, params)` sends a NOTICE with code CHAT, and the client still shows it in the system channel of the chat box.
- In L4a every current sender (party, chat router, moderation, progress replies and GM replies) sends `legacy.text` with its current Spanish text, so nothing visible changes. L4b–L4d replace those uses with real catalog entries: about 27 party texts, 9 chat router texts, 29 moderation texts players see, and the progress and `/unstuck` replies.

### 7.6 Client rendering

`ServerMessageText.render(block) -> String`:
- **Known id with parameters that match the catalog:** `L10n.tf(template, params, &"server")`, with each parameter formatted by its kind.
- **`legacy.text`:** the TEXT parameter, escaped, as today.
- **Unknown id or wrong parameter kinds:** "Message from the server." plus any TEXT parameters, and a `push_warning` once per id. The `SIM_HASH` check makes this unlikely, and it never disconnects.
- `NetClient.notice_received` carries the block, not text. `online_main`, the chat box, the notification centre (UI-08) and `bot_progress_scenario.gd` (which keeps the last notice) render it with `ServerMessageText` or describe it with `ServerMessages.describe`.

### 7.7 Version, platform and compatibility

- `PROTOCOL_VERSION` goes from 7 to 8 once, in L4a, covering NOTICE, the REJECT block and system chat.
- **The platform service embeds the protocol version and must move with it, in the same increment:**
  - regenerate `platform/internal/gamedata/progression_rules.json` with `godot --headless --path . -s res://tools/progression/export_rules.gd` (`protocol_version` 8); `tests/test_progression_rules_export.gd` fails until then, because it requires the file to match the build and `protocol_version == PROTOCOL_VERSION`;
  - `platform/cmd/eldmark-platform/main_test.go` sends `X-Eldmark-Protocol: 7` in its `request` helper; with the JSON at 8, `serve` resolves `MinProtocol` to 8 in `dev` and `test` and every request gets 426. The helper reads `gamedata.MustLoad().ProtocolVersion` instead, as the 426 test of the same file already does;
  - `platform/internal/platformtest` has `const Protocol = 7`, used as the services' minimum, as the request header and in the zone registration (`zone.go`). It is derived from `gamedata` too, so the next bump only regenerates the JSON;
  - `platform/e2e` already reads the JSON;
  - `platform/deploy/staging.env.example` and `production.env.example` set `ELDMARK_MIN_PROTOCOL=7`; they move to 8;
  - the "Plataforma" and "Plataforma e2e" CI jobs must pass. TEC-52, which rewrites the Go test messages, touches the same files: whichever lands second rebases.
- **Deployment** (note added to [platform.md](platform.md)): the v8 client, the v8 zones and `ELDMARK_MIN_PROTOCOL=8` go out in the same maintenance window. From then on a v7 client gets 426 `client_outdated` at login and, against a zone, `REJECT VERSION`, which it can still read. No v7 client has been published, so nobody is cut off in practice.
- **Fortress names need no wire change.** STRUCTURE spawns carry `definition_id`, and the client takes the name from the `FortressDefinition`.
- **NPC names:** when `npc_def_id != 0`, the client ignores `display_name` and translates the definition's name. Two NPCs have no definition today and send a Spanish `display_name` with `npc_def_id = 0`: the training dummy (`DUMMY_NAME = "Maniquí"`, spawned by default in the zone; the bench avoids it with `--no-dummies`) and the debug captain ("Capitán (prueba)"). L6b gives both an `NpcDefinition`.
- **`WarEvents`** already travels as ids (ENTITY_EVENT WAR). Only its text moves to the client (L5b).
- [networking.md](networking.md) §5.2 (catalog), §5.3 (REJECT) and §5.5 (NOTICE) are updated in L4a, with the message block as a new subsection.

### 7.8 Logs, records and tests

- **Logs:** the server logs the key and parameters in English, `notice party.declined(name=Bruno) -> peer 7`, built by `ServerMessages.describe(block)`.
- **Records** keep codes and raw text, never a translated sentence: the battle log and the saves already store ids and numbers; moderation reports and sanctions store the reason as written; the future chat log (SOC-15) stores system lines as a key and parameters.
- **Tests:** server tests compare keys and parameters, not sentences: `assert_server_message(notice, &"party.declined", {"name": "Bruno"})`. In L4a they compare `legacy.text` with the old Spanish text, and each of L4b–L4d moves its area to keys. The raw ENet attacker and fuzz tests are updated for the new layouts in L4a: `raw_enet_attacker.gd`, `test_net_messages*`, `test_net_loopback` and `test_net_processes`.

### 7.9 What stays free text

- Player names (NAME).
- Text written by people (TEXT): moderator reasons, the platform's maintenance message, `/broadcast`, kick reasons typed by staff, and staff replies (`staff.reply`, English from L8b).

Moderation can later add a reason category next to the free reason. The category would be a code, and it would be translated.

## 8. Game content data

### 8.1 Fields

Each `.tres` keeps a single copy of each text field, holding the English text. The extractor reads a table of fields per resource script:

| Script | Fields | Context | Where |
|---|---|---|---|
| `ItemDefinition` | `display_name`, `description` | `item`, `item_desc` | `data/items/**` |
| `RaceDefinition` | `display_name`, `description` | `race`, `race_desc` | `data/characters/races/*` |
| `AppearancePart` | `display_name` | `appearance_<part>` (hair, beard, marks...) | `data/characters/appearance_catalog.tres` |
| `AppearanceColor` | `display_name` | `appearance_<palette>` (skin, hair, eyes...) | same file |
| `NpcDefinition` | `display_name` | `npc` | `data/npcs/*` |
| `FortressDefinition` | `display_name` | `fort` | `data/fortresses/*` |
| `MapLandmark` | `label` | `place` | `assets/maps/vado_gris_map.tres` |

Phase 6-8 content adds the contexts below (the registry of the common contexts is fixed in the integrated content
design). They are all English `msgid`s in the `.tres` with the Spanish in `es.po`, extracted by the same table:

| Script | Fields | Context | Where |
|---|---|---|---|
| `QuestDefinition` | `title`, `summary`, `description`, `progress_text`, `completion_text` | `quest`, `quest_summary`, `quest_desc`, `quest_progress`, `quest_done` | `data/quests/**` |
| `QuestDefinition` | `translator_note` | (not a message: becomes a `#.` comment) | same |
| `QuestObjective` | `text` | `quest_obj` | same; also each `CommissionTemplate` entry |
| `QuestStage` | `text` | `quest_stage` | same |
| `LoreEntry` | `title`, `text` | `lore_title`, `lore` | `data/lore/**` |
| `WorldEventDefinition` | `display_name`, `description`, phase text | `event`, `event_desc`, `event_phase` | `data/events/*` |
| `CommissionTemplate` | `title` | `commission` | `data/commissions/*` |
| `TalentNode` | `display_name`, `description` | `talent`, `talent_desc` | talent trees |
| `SpecializationDefinition` | `display_name`, `description` | `specialization`, `specialization_desc` | specializations |
| `PassiveDefinition` (a talent or a rank) | `description` | `passive_desc` | trees and specializations |
| Attribute | `display_name` | `attribute` | the five attributes |
| `AbilityDefinition` | `display_name`, `description` | `ability`, `ability_desc` | weapons (until now in `CombatText`) |
| `AffixDefinition` | `display_name` | `affix` | `data/items/affixes.tres` |
| `ProfessionDefinition` | `display_name` | `profession` | professions |
| `NpcDefinition` | `title` | `npc_title` | `data/npcs/*` |
| NPC family | `display_name` | `npc_family` | `data/npcs/families.tres` |
| `DialogueNode` | `text` | `dialogue` | `data/dialogues/*` |
| `DialogueOption` | `text` | `dialogue_option` | same |
| Ambient phrases and shouts | `text` | `bark` | NPC definitions |
| Interaction type | verb ("Talk", "Open", "Read") | `interact_verb` | interaction table |
| Zones, places, camps, poles and passes | `display_name` / `name_msgid` | `place` | zone definitions, `NpcCamp`, `TravelPoint` |

The limits per field (title 32 characters, offer 600, lore 1 200...) are in [quests.md](quests.md) section 7.2, and the
validator of the quest tools checks them with the entry in `es.po` in strict mode.

**Sentences and nouns.** A sentence is never built around a noun placeholder. "Hunt {count} {target}" cannot be
translated well: Spanish needs "Caza 8 lobos", "Caza 8 jabalíes" and "Mata a 8 desertores", with the gender, number and
verb that follow the noun. Each entry carries its whole sentence and only numbers as parameters
(`Wolves hunted: {count}/{total}`); a name of a person goes in a NAME parameter. A quest title or an event name that
travels in a notice is a whole parameter of kind QUEST or EVENT, printed by the client with its own context (section 7.2),
never a word inside the sentence.

**Translator note.** Dialogue lines, quest descriptions and lore carry a mandatory translator note (`translator_note`
in the resource; `#.` in the template): who speaks, in what tone and where it is seen. The validator fails a description
or a dialogue without it.

- No duplicated resources and no Godot remaps. The extractor works out the script of each `[resource]` and `[sub_resource]` block; `appearance_catalog.tres` has 29 sub-resources.
- The client translates where it shows the value (`ItemText.name(def)`, `NpcText.name(def)` and so on). The server only uses `display_name` in logs, where English is fine.
- The context per palette keeps the Spanish gender right: "Light" skin is "Clara", "Light brown" hair is "Castaño claro".
- The fort landmark's label is written by `tools/zone_map_baker.gd` from the fort's `display_name`. In L6b the client stops reading that copy and takes the name from the `FortressDefinition` through the landmark's `fortress_id`; the baker keeps writing the English name.
- Some content lives in client code: the ability, status, weapon and template titles in `CombatText`, the place names in `zone_places.gd` and the realm lore. They use the same contexts. Moving them into `.tres` files is optional.
- Descriptions that contain balance numbers use placeholders filled from the data (rule 6).
- `ItemDatabase.wire_hash()` and `CombatCatalog.prediction_hash()` stay as they are; both ends are built from the same commit anyway.

### 8.2 Proper names

Decided: **descriptive names are translated, invented names stay as they are.** All of them still go through the catalog (`place`, `fort`, `realm`, `npc`), so a future language can adapt any of them without touching code, and the "looks Spanish" check of `l10n_po.py` has an allowlist for the invented ones.

Glossary to start from, consistent with [world.md](world.md) and the README. Each increment reviews the names it touches; `es.po` keeps the current Spanish verbatim.

| Spanish | English | Kind |
|---|---|---|
| Vardheim, Solmarch, Askarra, Eldrun, Eld, Vado Gris, Isenholm, Aldcor | unchanged | invented |
| los Huecos (faction) / Hueco (NPC) | the Hollow / Hollow | descriptive |
| Fuerte del Vado Gris | Vado Gris Fort | mixed |
| Capitán del Vado | Ford Captain | descriptive |
| Guardián de la Puerta, Capitán del reino, Guardia del reino | Gate Guardian, Realm Captain, Realm Guard | descriptive |
| Maniquí | Training Dummy | descriptive |
| Campamento de Vardheim / de Solmarch | Vardheim Camp / Solmarch Camp | mixed |
| Puerta del Muro de Escarcha / de la Muralla del Alba | Frost Wall Gate / Dawn Wall Gate | descriptive |
| Puente del Norte / del Sur, El Vado | North Bridge / South Bridge, The Ford | descriptive |
| Ruinas de Eld, Capilla en ruinas | Ruins of Eld, Ruined Chapel | mixed / descriptive |
| Pinar de Escarcha, Arboleda del Alba | Frost Pines, Dawn Grove | descriptive |
| Río Eldrun, Sierra del Poniente / del Levante | Eldrun River, Western Ridge / Eastern Ridge | mixed / descriptive |
| Gente de Vardheim | People of Vardheim | mixed |

Additions for the phase 6-8 content (quests, story, world, specializations and items). The names of the story are those
of [story.md](story.md); they stay provisional until the user confirms the bible (P3).

| Spanish | English | Kind |
|---|---|---|
| Hondal, Granvik, Eldhald, Hrimgard, Skarven, Grimfell | unchanged | invented |
| los Desjurados / Desjurado | the Forsworn / Forsworn | descriptive |
| los Juramentados | the Oathbound | descriptive |
| Juramento de las Tres Sangres | Oath of the Three Bloods | descriptive |
| Ecos de Eld | Echoes of Eld | mixed |
| el Senescal Corvan | Seneschal Corvan | mixed |
| Brasas de Eld | Embers of Eld | mixed (canon of [world.md](world.md)) |
| Esquirla de Brasa | Ember Shard | descriptive |
| Lluvia de Brasas | Ember Rain | descriptive |
| Nova de Brasas | Ember Nova | descriptive |
| Incursión de los Huecos | Hollow Incursion | descriptive |
| Pilar de Granvik | Granvik Pillar | mixed |
| Tablón de encargos / encargo | Commission Board / commission | descriptive |
| Llamada a las armas | Call to Arms | descriptive |
| La Elección del Escudero | The Squire's Choice | descriptive |
| Salón de Armas | Hall of Arms | descriptive |
| Maestre de las Órdenes | Master of the Orders | descriptive |
| Glaciar de Hrimvald | Hrimvald Glacier | mixed |
| Altos de Vaucelle | Vaucelle Heights | mixed |
| Salares de Qesh | Qesh Salt Flats | mixed |
| Campos de Ambre | Amber Fields | descriptive (zone, [world.md](world.md) §3.2) |
| Oasis de Thal | Thal Oasis | mixed (zone) |
| Bosque de Lirien | Lirien Forest | mixed (zone) |
| Cañones de Ruhn | Ruhn Canyons | mixed (zone) |
| Ciénaga de Morvel | Morvel Marsh | mixed (zone) |
| Yermo de Ceniza | Ash Waste | descriptive (zone) |
| Marca del Lobo | Wolf March | descriptive (zone) |
| Llanos del Penitente | Penitent Plains | descriptive (zone) |
| Forjas de Ossar | Ossar Forges | mixed (zone) |
| Osarios de Eld | Ossuaries of Eld | mixed |
| Acueducto Hundido | Sunken Aqueduct | descriptive |
| Archivo del Juramento | Oath Archive | descriptive |
| Fundición de la Llama | Flame Foundry | descriptive |
| Raíces de la Quiebra | Sundering Roots | descriptive |
| Cámara del Último Rey | Last King's Chamber | descriptive |
| Vanguardia | Vanguard | descriptive (specialization) |
| Rompefilas | Linebreaker | descriptive (specialization) |
| Cazador | Hunter | descriptive (specialization) |
| Sanador | Healer | descriptive (specialization) |
| Arcanista | Arcanist | descriptive (specialization) |
| Zapador | Sapper | descriptive (specialization, phase 7) |
| Hoja de guerra | War Sheet | descriptive |
| Sello de veterano | Veteran Seal | descriptive |
| Puntuación de equipo | Equipment Score | descriptive |
| alforja | Loot Satchel | descriptive |

## 9. Chat commands and other typed input

Decided: **canonical English ids; the long names work in both languages; the short aliases follow the client's language.**

| Id | Long names (always) | English short | Spanish short |
|---|---|---|---|
| `say` | `/say`, `/decir` | `/s` | `/d` |
| `zone` | `/zone`, `/zona` | `/z` | `/z` |
| `whisper` | `/whisper`, `/susurrar` | `/w` | `/s` |
| `reply` | `/reply`, `/responder` | `/r` | `/r` |
| `party` | `/party`, `/grupo` | `/p` | `/g` |
| `invite`, `leave`, `kick`, `leader` | `/invite` `/invitar`, `/leave` `/salir`, `/kick` `/expulsar`, `/leader` `/lider` | — | — |
| `ignore`, `unignore`, `report` | `/ignore` `/ignorar`, `/unignore` `/designorar`, `/report` `/reportar` | — | — |
| `help` | `/help`, `/ayuda` | — | — |
| `gm` | `/gm` | — | — |

- `/s` is the only clash: say in an English client, whisper in a Spanish one. Players who learned the Spanish aliases keep them as long as their client is in Spanish, and the long names work everywhere.
- The client parser maps what the player types to the id and sends the canonical form. The server only knows canonical names: today `moderation_service.gd` (`ignorar`, `reportar`) and `command_registry.gd` (`ayuda`) match Spanish words. Client and server are always the same build, so no transition period is needed.
- `ChatCommandParser.COMMANDS` keeps the typed names, which are data, apart from the usage and help texts (`# l10n ctx=chat_command fields=usage,help`). The usage line is built with the alias of the current language: `{command} [text]`.
- **`/report` categories:** the words of both languages map to the platform codes that already exist (`language`/`lenguaje`, `harassment`/`acoso`, `cheating`/`trampas`, `bot`, `name`/`nombre` → `offensive_name`, `other`/`otro`).
- **Help:** `/help` and `/ayuda` list the commands in the current language, with their usage text from the catalog.
- **Staff keywords** (L8b): the words staff type in GM and console commands accept both languages (`gold`/`oro`, `merits`/`meritos`), and their usage texts are English.
- **Names:** the logic of `NameRules` does not depend on language (letter whitelist, accent folding). The reserved words gain their English forms ("Guard", "Captain", "Hollow"...). The default name prefix in development follows the language ("Player" or "Jugador"). The Go copy (`platform/internal/names`) is regenerated from `ProgressionRulesExport`, and its fixtures keep reason codes.
- **Profanity filter (SOC-27):** designed with Spanish and English lists from the start.

## 10. Tooling (`tools/i18n`)

The new tools reuse `i18nlib.py`, the lexers of the comment translation tools. Python 3.14 and the standard library only; no gettext install needed on Windows.

### 10.1 `l10n_extract.py`: the template (L1b)

Builds `locale/eldmark.pot` from:
- `L10n` calls with literal arguments, read **by position** according to each signature, with balanced parentheses, so the keys of a parameter dictionary are never taken as text:

| Call | `msgid` | plural | context |
|---|---|---|---|
| `L10n.t(msgid, ctx)`, `L10n.mark(msgid, ctx)` | 0 | — | 1 |
| `L10n.tn(msgid, plural, n, ctx)` | 0 | 1 | 3 |
| `L10n.tf(msgid, params, ctx)` | 0 | — | 2 |
| `L10n.tfn(msgid, plural, n, params, ctx)` | 0 | 1 | 4 |
| `L10n.bind(node, msgid, ctx, property)` | 1 | — | 2 |

- `# l10n` constants (with `fields=`) and `TRANSLATORS:` comments;
- the text properties of the `.tscn` files and the fields of 8.1 in the `.tres` files, **only for the paths listed in `tools/i18n/l10n_scope.txt`**. Code calls are explicit marking, so they are extracted from all of `scripts/client`; scenes and resources have no explicit marking, so they wait until their increment adds them to the scope. Otherwise the 12 Spanish texts of `realm_select.tscn` and all of `data/` would enter the template as Spanish `msgid`s in L1b;
- the server message templates and the formatting entries.

String literals are decoded exactly as GDScript does (`\n`, `\t`, `\"`, `\\`, `\uXXXX`, `\UXXXXXX`, raw strings), with a self-test that compares against Godot's own reading of a fixture file. `--check` exits with code 1 when the versioned template is out of date. The same input always gives the same bytes.

### 10.2 `l10n_po.py`: keeping `es.po` in step (L1b)

- `--update` does what `msgmerge` does: adds new entries with an empty `msgstr`, moves removed entries to the end as obsolete (`#~`), copies references and translator comments from the template, and keeps the translator's own comments.
- `--check` fails on an empty or fuzzy entry, an obsolete entry left behind, an entry that is not in the template, a placeholder or BBCode mismatch, the wrong number of plural forms, or a `msgid` that looks Spanish (2.2). If `msgfmt` is installed, it also runs `msgfmt --check`.

### 10.3 `l10n_scan.py`: unmarked visible text (L1c)

- **Scope:** `tools/i18n/l10n_scope.txt` lists the files and globs already migrated; every increment adds its own. At the end (UI-39) it covers `scripts/client/**`, `scenes/**` and `data/**`, plus the rule that `scripts/shared` and `scripts/server` hold no player text.
- **It fails on:**
  - a literal that looks like visible text (a word of two or more letters and a space, a capital followed by lowercase letters, or non-ASCII letters) that is not inside a marking call, not in a `# l10n` constant and not on a line with `# l10n-ignore: <reason>`. Excluded: `StringName` and `NodePath` literals, paths and identifiers, strings inside log calls (`print*`, `push_error`, `push_warning`, `assert`...), node, signal, method, action and metadata names, dictionary keys, `match` patterns and comparison operands;
  - a **text sink** fed by a literal, by a same-file constant that is not marked, or by a literal formatted with `%`: `.text =`, `.tooltip_text =`, `.placeholder_text =`, `.title =`, `add_item(`, `set_item_text(`, `set_tab_title(`, `draw_string(`, `draw_string_outline(` and `UIFonts.draw_text(`. This catches the short labels the word heuristic misses;
  - a constant table whose strings are all short capitals (`["N", "NE", "E", "SE", "S", "SO", "O", "NO"]` in `compass.gd`) and that is neither marked nor ignored;
  - a bare `draw_string` in a migrated file (rule 10);
  - a `.tscn` text in scope that is missing from the template.
- **`--report`** prints the candidates of a file outside the scope. That list is the input of the migration.
- Indirect paths (a table read through a helper function) are not traced; the runtime screen test (11) is the safety net for them.

### 10.4 `l10n_migrate.py`: mechanical migration (L1c)

The flow is the one of the comment translation: extract segments, translate them in lanes, apply them, prove the result.

1. `extract --files <globs>` writes one segment per candidate literal: the file, the line, the Spanish text, the context line and a proposed treatment.
2. The translator (an agent) fills in the English text, an optional context and the treatment:
   - `t`: the literal becomes `L10n.t("<English>")` where it stands;
   - `bind`: `node.text = "<Spanish>"` becomes `L10n.bind(node, "<English>")`, also for `tooltip_text`, `placeholder_text` and `window_title`, only for nodes whose text is assigned once;
   - `mark` and `const`: **only for a literal stored as it is**, never for one that is formatted (`%`) or concatenated before it is stored. The literal becomes the English text (in `L10n.mark(...)`, or in a constant with `# l10n`), and every read outside the tests is wrapped in `L10n.t(..., ctx)`;
   - `ignore`: not interface text, so `# l10n-ignore` is added;
   - `manual`: everything else, including stored formatted text and reads through other files, listed for the hand pass.
3. `apply` rewrites the files and adds every pair to `es.po`: the English as `msgid` and the old Spanish, verbatim, as `msgstr`. Two different Spanish texts for the same English and context are refused.
4. `verify --base main` proves the change:
   - **GDScript:** compares token streams; the files may only differ by a literal replaced by its English (whose `es.po` entry is exactly the old text), `L10n` wrappers around an expression, `bind` replacing a text assignment to the same node, and `# l10n` comments;
   - **`.tscn` and `.tres`:** compares properties; only the text properties of 5.1 and the fields of 8.1 may change, each new value must be a `msgid` whose `msgstr` is the old value, and the scene's script must call `bind_scene`.

`verify` alone does not prove that Spanish players see the same text: it cannot follow a stored `msgid` to the place where it is shown. Together with the Spanish snapshots (12.2), it does. Each increment is therefore two kinds of commits: the mechanical one, which `verify` passes, and the hand one, reviewed normally (templates instead of concatenations, `_refresh_texts()`, grammar and tests).

### 10.5 `l10n_rewrite_tests.py`: Spanish assertions (L1c)

For each string literal in the arguments of an `assert_*` call in `tests/` (not the assertion message):
- **equal to a `msgstr`:** replaced by its `msgid`;
- **matching a `msgstr` template with placeholders** (`%d`, `%s` and `{name}` as captures, unique match): replaced by the English template with the same values ("Huecos libres: 2 de 3" → "Free slots: 2 of 3");
- **ambiguous or not found:** listed for hand editing.

The suite then runs to confirm. Spanish used as data is never touched, because it is not a `msgstr`: names such as Álvaro or Ñandú in `test_name_rules`, or chat text.

### 10.6 Continuous integration

A "Localización" job in `.github/workflows/tests.yml` (setup-python 3.14) runs `test_i18n.py`, `l10n_extract.py --check` and `l10n_po.py --check` from L1b, and `l10n_scan.py --check` from L1c. "Suite completa" requires it. The Godot suite runs the GDScript checks of section 11 in its shards.

## 11. Guarantees

| Risk | What catches it | From |
|---|---|---|
| A lookup with no Spanish entry: missing `msgid`, misspelled context, Spanish passed as `msgid`, text formatted before the lookup | Strict mode in every test (4.6) | L1a |
| Spanish players see something different after a migration | The Spanish snapshot of each migrated screen (12.2), plus `l10n_migrate.py verify` | L1a / L1c |
| Text on screen that did not go through `L10n`, or that does not refresh on a language change (labels, buttons, tab titles, option items, placeholders, tooltips, `RichTextLabel`, drawn text) | `tests/test_l10n_screens.gd` with pseudolocalization (12.2) | L1a |
| The language of a test depends on the machine | `L10n.force("en")` and temporary settings in the runner (12.1) | L1a |
| The engine translates something by itself | `test_l10n_runtime.gd` checks that the main domain stays empty and that an orphan `Label` is not translated | L1a |
| A character missing from the fonts | `tests/test_l10n_glyphs.gd` | L1a |
| Shared or server code that translates, or a `tr()` anywhere | `tests/test_architecture.gd` | L1a |
| Translations missing from the client export, or present in the server's | `tests/test_export_config.gd` | L1a |
| The template was not regenerated after a text change | `l10n_extract.py --check` (CI) | L1b |
| An empty, fuzzy or obsolete entry, mismatched placeholders, a `msgid` that looks Spanish | `l10n_po.py --check` (CI) | L1b |
| Godot reads an entry differently from the extractor (escapes) | `tests/test_l10n_catalog.gd`: every template entry resolves in the loaded `es.po` | L1b |
| Visible text without marking in a migrated file or `.tscn` | `l10n_scan.py --check` (CI) | L1c |
| A mechanical migration that changed anything else | `l10n_migrate.py verify`, with its output in the PR description | L1c |
| A server message id without a client template, or with other placeholders | `tests/test_server_message_text.gd` | L4a |

## 12. Tests

### 12.1 Which language the tests run in

- **Fixed language.** Before each test, `tests/run_tests.gd` calls `L10n.force("en")`, turns strict mode on, turns pseudo off and clears the misses and the drawn-text records. A forced language cannot be overridden by the saved setting, so `ClientServices` applying a stored `language`, or "Restore all" emitting `changed`, cannot switch the language in the middle of a test.
- **No real settings file.** `ClientSettings` gets a `static var default_path` (`user://settings.cfg` by default). The runner points it to an empty temporary file before each test (named after the process and the shard, so suites running at once never share it, and deleted when the run ends) and calls `ClientSettings.set_current(null)`. Today `test_front_main`, `test_online_main`, `test_client_zone`, `test_realm_select` and `test_account_flow` mount scenes with `ClientServices`, which reads and writes the developer's real `user://settings.cfg`.
- **Spawned processes.** Tests that start client processes pass `--locale=en` (`tests/net_harness.gd` and the others that launch a client; `process_probe.gd`, `test_combat_processes` and `test_fortress_processes` start servers or scripts, not clients, so they do not need it).
- `TestCase.with_locale(code)` forces another language for one test; the runner restores English before the next one. A few tests check the Spanish on purpose: tab names, the decimal comma, the date pattern and one sentence per catalog.
- **Why English and not Spanish:** English is what the code says. With the suite in Spanish, a community edit of `es.po` could break CI, and new tests would compare against translations instead of the source.

### 12.2 Screen tests: Spanish snapshot and pseudo

`tests/test_l10n_screens.gd` builds each screen in its list with fixed data (as the existing UI tests do) and runs two checks:

1. **Spanish snapshot.** With `es` forced, `tests/l10n_screen_probe.gd` collects the visible texts in tree order: labels, buttons, tab titles, option items, placeholders, tooltips, parsed `RichTextLabel` text and the drawn strings recorded by `note_drawn`. Each line is `<kind>\t<text>`, without node paths, so renaming nodes does not matter. The result must equal `tests/l10n_golden/<screen>.es.txt`.
   - The golden file is written **before** the screen is migrated, from the Spanish literals, in the first commit of the increment (`-- --l10n-write-golden`).
   - When an increment changes Spanish on purpose (a sentence that was built from pieces, a plural), it rewrites the golden file in a separate commit, so the reviewer sees exactly what Spanish players will see differently.
2. **Pseudo refresh.** The screen is built in English, then switched to `pseudo` with the screen open, without forcing anything else. After one frame, every visible text that contains a letter or a digit, and every string drawn in that frame, must be wrapped in `¦…¦`. Raw nodes are skipped. That proves the text goes through `L10n` and refreshes. For the settings window, the switch is made from its own language selector.

A screen enters the list with only the snapshot active and gets the pseudo check when it is migrated.

### 12.3 Migrating the ~480 Spanish assertions

| Kind | Example | How | When |
|---|---|---|---|
| Client interface text | `assert_eq(menu.window_title, "Ajustes")` | `l10n_rewrite_tests.py` → `"Settings"` (by hand in L1a and L1b) | in the increment that migrates the screen |
| Server text | `_last_system(ana) == "Bruno ha rechazado tu invitación."` | by hand → key and parameters | L4a (as `legacy.text`), then L4b–L4d |
| Platform messages | `"Correo o contraseña incorrectos"` | rewriter (the client translates by code) | L2a |
| Log lines | `log_text.contains("Cuenta atrás de cierre cumplida")` | changed to English together with the log literal | L8a, L8b |
| Spanish as data | `Álvaro`, chat text | untouched | — |

The heaviest files are `test_party_manager` (38), `test_gm_progress` (23), `test_command_registry` (22), `test_inventory_window` (22), `test_front_screens` (19) and `test_zone_moderation` (16).

## 13. Captures per increment

Every increment ends with the same screens captured with the quality bench (`tools/quality/run.py`) in Spanish and in English, and in pseudolocalization when the increment is about lengths. The pairs are composed side by side and archived outside the repository, in the capture archive next to it (`../Eldmark-capturas/`), as for the quality waves.

**Bench changes (L1a):**
- `run.py` gets `--locale es|en|pseudo` (default `es`, so existing commands keep producing the Spanish captures). It adds `--locale=<code>` to the user arguments of every client it starts (the `online_driver.gd` runs, the gallery, the chat preview and the offline demo), never to the server or the bots.
- `sc_interfaz.gd` names the settings captures after the tab id through a fixed slug table (`graphics → graficos`, `audio → audio`, `camera → camara`, `interface → interfaz`), so the file names stay those of the existing archive instead of depending on the tab title.
- `sc_front.gd` adds a light capture of the settings window over the title screen (`interfaz/titulo_ajustes_f10_<n>_<slug>.png`), which needs no server. The in-game ones (`interfaz/ajustes_f10_<n>_<slug>.png`, step `hud`) need a dedicated server and 6 bots per realm.

**Steps** (`python tools/quality/run.py listar`): `interfaz` has `hud`, `marcador` and `reino`, which start a dedicated server with bots, and `titulo`, `galeria` and `chat`, which do not; `mapa` starts a server. Each increment names its steps in section 14.

**Commands** (L1a as the example):

```sh
python tools/quality/run.py interfaz --steps titulo --locale es --out build/calidad/l10n/L1a/es
python tools/quality/run.py interfaz --steps titulo --locale en --out build/calidad/l10n/L1a/en
python tools/quality/run.py interfaz --steps titulo --locale pseudo --out build/calidad/l10n/L1a/pseudo
python tools/quality/compare_before_after.py build/calidad/l10n/L1a/es/interfaz build/calidad/l10n/L1a/en/interfaz \
    --out build/calidad/l10n/L1a/es_en --pattern "titulo_ajustes_*.png" --label-before ESPAÑOL --label-after ENGLISH
```

`compare_before_after.py` pairs the files with the same name in two folders (not recursive), so it is pointed at the area folder (`interfaz`, `mapa`).

**Archive:** `../Eldmark-capturas/<date>_localizacion_<Lxx>/` with `es/`, `en/`, `pseudo/` and `es_en/`. The increment adds its job to `archivar.py` and a row to the table of `LEEME.md` in that archive.

## 14. Increments

| # | Backlog | Scope | Size | After | Captures (bench step) |
|---|---|---|---|---|---|
| L1a | UI-57 | `L10n` runtime, language setting, settings window by hand, test policy, snapshot and pseudo tests, glyph test, bench `--locale` | M | waves merged, TEC-51, TEC-54 | `interfaz --steps titulo` (settings over the title) |
| L1b | TEC-55 | Template extractor, `es.po` tool, CI job; development realm choice (`.tscn`), `NameRuleText`, `RealmText` | M | L1a | `interfaz --steps reino` |
| L1c | TEC-56 | Scan, mechanical migration with proof, test rewriter; proven on the title and login screen | M | L1b | `interfaz --steps titulo` |
| L2a | UI-58 | Account screens: register, terms panel, sanctioned account, rename; platform errors by code; dates | M | L1c | `interfaz --steps titulo` |
| L2b | UI-59 | Character select and create, races and appearance from `data/characters`, realm lore | M | L2a | `interfaz --steps titulo` |
| L2c | UI-60 | Loading, connection and disconnection; REJECT by `Result` in the client | S | L2b | `interfaz --steps hud,titulo` |
| L3a | UI-61 | Combat HUD: `CombatText`, action bar, vitals, status icons, death screen, downed notice, respawn list, template selector; `UIFonts.draw_text` | M | L1c | `interfaz --steps hud,marcador` |
| L3b | UI-62 | Hints, help line (F1), key names, nameplates, kill feed | S | L3a | `interfaz --steps hud` |
| L4a | TEC-57 | Protocol 8 wire format with `legacy.text`; platform Go; networking.md | M | L1b | `interfaz --steps hud,chat` |
| L4b | TEC-58 | Server operation, session and authentication messages; REJECT blocks; `result_text` and `NameRules` text leave shared code | S | L4a, L2c | `interfaz --steps hud,titulo` |
| L4c | TEC-59 | Party and chat router messages | S | L4b | `interfaz --steps chat` |
| L4d | TEC-60 | Moderation, progress and `/unstuck` messages; `legacy.text` retired | S | L4c | `interfaz --steps chat,hud` |
| L5a | UI-63 | Chat box and commands, party invitation and frame, social menu | M | L4c, L3b | `interfaz --steps hud,chat` |
| L5b | UI-64 | War: banners, capture panel, objective line, boss bar, scoreboard, fort names | M | L5a | `interfaz --steps hud,marcador` |
| L6a | UI-65 | Items, inventory, tooltips, rarities, split and destroy dialogs, character window | M | L3a | `interfaz --steps hud,galeria` |
| L6b | UI-66 | NPCs, forts and map: world map, minimap, compass, world markers, landmarks, `zone_places.gd`; definitions for the dummy and the debug captain | M | L5b | `mapa` and `interfaz --steps hud` |
| L7a | TEC-61 | Platform: account language, API messages in English, e-mails per language | M | L2a | `interfaz --steps titulo` |
| L7b | TEC-62 | Platform: legal texts and news per language, web pages, terms panel | S | L7a | `interfaz --steps titulo` |
| L8a | TEC-63 | Developer text in English, client and tools | S | L1c | `interfaz --steps hud,galeria` |
| L8b | TEC-64 | Developer and staff text in English, server; staff keywords | M | L4d | `interfaz --steps chat` |
| — | UI-39 | Final review in English, Spanish and pseudo; `auto` follows the OS | S | L1a–L7b | the whole bench |

The recommended order is the one of the table. After L1c, the front end (L2), the HUD (L3), the protocol (L4), the items (L6a), the platform (L7) and the developer text (L8a) depend on each other only where the column says, so their order can change.

### L1a: runtime, language setting and settings window (UI-57, M)

- **Scope:**
  - `tests/test_l10n_runtime.gd`: the facts of 4.1 as regression tests, with a small fixture `.po`;
  - `L10n` (4.2): private domain, lazy install, `force`, `set_language`, `t/tn/tf/tfn/mark`, `bind/unbind/raw`, own pseudolocalization, strict mode, `format_int/decimal/percent/duration`, `quote`, `escape_bbcode`;
  - `locale/es.po`, written by hand (no template until L1b): the settings window, the audio bus names, the dialog defaults and the language options, about 70 entries;
  - `project.godot` (3), export filters and `test_export_config.gd`;
  - `--locale=` read by `L10n` and accepted by `boot.gd` (today the sandbox warns "Argumento desconocido" for any argument it does not list, which `test_client_launcher` checks); `ClientServices` applies the setting before the first screen;
  - the `language` setting (4.3), not restorable;
  - the settings window (F10) migrated by hand: the schema stores `msgid`s, contexts and parameters; one label per audio bus ("Music volume" → "Volumen: Música") instead of `"Volumen: %s" % AudioBuses.display_name(bus)`; the FPS labels built when shown; `format_value` through `L10n`; tabs named after their ids with `set_tab_title`; `_refresh_texts()` in place; the language applied deferred;
  - `UIConfirmDialog` translates its defaults when it opens and keeps its API (callers pass translated text); it goes in `L10N_REFRESH_ON_OPEN`, because it is modal;
  - test policy (12.1): `run_tests.gd`, `test_case.gd`, `ClientSettings.default_path`, `--locale=en` in the process helpers;
  - `tests/l10n_screen_probe.gd`, `tests/test_l10n_screens.gd` and the golden files of the four tabs and the confirmation;
  - `tests/test_l10n_glyphs.gd` (the fonts are on `main` since the waves merge);
  - `tests/test_architecture.gd` rules (6);
  - bench changes (13);
  - this document, and the rule for interface text in `CLAUDE.md` and `CONTRIBUTING.md`.
- **Main files:** new `scripts/client/l10n/l10n.gd`, `locale/es.po`, the four tests and `tests/l10n_golden/`; changed `project.godot`, `export_presets.cfg`, `scripts/boot.gd`, `scripts/client/client_services.gd`, `ui/client_settings.gd`, `ui/settings_menu.gd`, `ui/ui_confirm_dialog.gd`, `audio/audio_buses.gd`, `tests/run_tests.gd`, `test_case.gd`, `net_harness.gd`, `test_settings_menu.gd`, `test_client_settings.gd`, `test_client_launcher.gd`, `test_architecture.gd`, `test_export_config.gd`, `test_quality_tools.gd`, `tools/quality/run.py`, `sc_front.gd`, `sc_interfaz.gd`.
- **Done when:**
  - the settings window shows everything in English, Spanish and pseudo, and its Spanish snapshot is identical to the one taken before the change;
  - choosing English in its own selector switches the open window, and the choice survives a restart; `--locale` overrides it without saving;
  - "Restore all" leaves the language alone;
  - with `auto`, the game is still in Spanish on any OS;
  - the suite passes in English with any `settings.cfg` on the machine, and fails when a lookup has no Spanish entry;
  - an exported client loads `es.po`;
  - captures of the four tabs (over the title) in Spanish, English and pseudo, side by side, are archived.
- **Risks:** an engine fact that differs on the CI's Linux runner (the runtime test shows it); the tab node names change, which touches tests and the bench; the hand-written `es.po` must match exactly what the extractor produces in L1b (the strict mode and the catalog test check it).

### L1b: template, `es.po` tool and the realm choice (TEC-55, M)

- **Scope:**
  - `l10n_extract.py` (10.1) with escape decoding and its self-tests, and `locale/eldmark.pot` generated from L1a's code;
  - `l10n_po.py --update/--check` (10.2) and `tests/test_l10n_catalog.gd`;
  - the "Localización" CI job (10.6);
  - `tools/i18n/l10n_scope.txt`, with L1a's files and `scenes/ui/realm_select.tscn`;
  - the development realm choice: the `.tscn` texts bound with `bind_scene`, the realm names from `RealmText` instead of being repeated in the scene, and the name and address errors through `NameRuleText` (client, from `NameRules` codes and limits; the shared text helpers stay for the server until L4b);
  - `tools/i18n/README.md`.
- **Done when:** CI fails on an outdated template or an untranslated entry; the bench step `reino` (`eleccion_de_reino_01`–`05`) comes out complete in English and Spanish, with its Spanish snapshot unchanged.
- **Risks:** the extractor and Godot reading an entry differently (the catalog test); the realm choice is a development screen, but it is the first `.tscn` and exercises `bind_scene`.

### L1c: migration tools, proven on the title screen (TEC-56, M)

- **Scope:** `l10n_scan.py` (10.3), `l10n_migrate.py` with `verify` for GDScript, `.tscn` and `.tres` (10.4), `l10n_rewrite_tests.py` (10.5), their self-tests and the scan in CI. Their first real run migrates the title screen (sign in, forgot password).
- **Main files:** `tools/i18n/l10n_scan.py`, `l10n_migrate.py`, `l10n_rewrite_tests.py`, `test_i18n.py`, `scripts/client/ui/title_screen.gd`, `front_screen.gd`, `tests/test_front_screens.gd`.
- **Done when:** the scan fails on an unmarked string in a migrated file; `verify` passes on the mechanical commit and rejects a doctored one; the bench captures `titulo_01_inicio` and `titulo_02_olvide_contrasena` come out in English and Spanish.
- **Risks:** the tools are the bulk of the work; validating them on real strings is the point of migrating one screen here.

### L2a: account screens (UI-58, M)

- **Scope:** register, terms panel (its frame; the legal text comes from the platform until L7b), sanctioned account, rename; `PlatformErrors.TEXTS` as a marked table by code; dates through `L10n`; hand fixes: "Acepto %s", which inserts a title carrying its own article, becomes one sentence per document; " hasta el %s" becomes whole templates; "7 días" and "14 días" become plurals with the number taken from config.
- **Main files:** `scripts/client/ui/register_panel.gd`, `terms_panel.gd`, `sanctioned_panel.gd`, `rename_dialog.gd`, `scripts/client/platform/platform_errors.gd`, `account_flow.gd`; tests `test_front_screens`, `test_account_flow`, `test_platform_api`.
- **Done when:** `titulo_03_registro` and three new captures added to `sc_front.gd` with fake data (`titulo_04_terminos`, `titulo_05_cuenta_sancionada`, `titulo_06_renombrar`) come out in English and Spanish. What the platform writes (legal text, sanction reason) may still be Spanish.
- **Risks:** the `LineEdit` context menu (Cut, Copy, Paste) is engine text and stays English in both languages; disable it on game fields or accept it. Buttons sized to long Spanish labels.

### L2b: characters (UI-59, M)

- **Scope:** character select and create, `character_figure.gd`, races and appearance (`data/characters/**`, contexts of 8.1), realm lore and names, the `▶ ◀` arrows left for UI-39.
- **Main files:** `scripts/client/ui/character_select.gd`, `character_create.gd`, `character_figure.gd`, `data/characters/**`, `tests/test_front_screens.gd`.
- **Done when:** `seleccion_personaje_01`–`04` and `creacion_01`–`04` come out in English and Spanish, and `verify` passes on the `.tres` changes.
- **Risks:** appearance names with gender agreement in Spanish (one context per palette).

### L2c: connection and rejections (UI-60, S)

- **Scope:** the loading, connecting and disconnection texts (`NetClient.disconnected` carries a reason code); `RejectText` in the client, by `Result`; `online_main.gd` and `front_main.gd` texts, including the default development name prefix. For TICKET, UNAVAILABLE and BANNED, whose text the server or the platform may write, the client keeps showing that text until L4b.
- **Main files:** `scripts/client/online_main.gd`, `front_main.gd`, `net_client.gd`, `scripts/client/l10n/reject_text.gd`; tests `test_net_client`, `test_front_main`, `test_online_main`.
- **Done when:** `carga_01`… (step `hud`) and a new forced rejection capture in `sc_front.gd` (`titulo_07_rechazo`) come out in English and Spanish.

### L3a: combat HUD (UI-61, M)

- **Scope:**
  - `CombatText`: abilities, statuses, weapons, templates and the death causes with their article (context `cause`);
  - action bar, vitals, status icons, icon slots (cooldowns through `format_decimal`), downed notice, death screen, respawn point list, template selector, placeholder icons;
  - `UIFonts.draw_text` and `L10n.note_drawn`, with `vitals_hud`, `status_icons`, `ui_icon_slot` and `placeholder_icon` moved to it;
  - tooltip numbers taken from the data.
- **Main files:** `scripts/client/combat_text.gd`, `action_bar.gd`, `hud.gd`, `vitals_hud.gd`, `status_icons.gd`, `downed_notice.gd`, `death_screen.gd`, `respawn_point_list.gd`, `template_selector.gd`, `ui/ui_icon_slot.gd`, `ui/placeholder_icon.gd`, `ui/ui_fonts.gd`; tests `test_action_bar`, `test_hud_combat`, `test_combat_feedback`.
- **Done when:** `hud_en_pelea_*`, `pantalla_de_muerte`, `tras_reaparecer` and `derribado_aviso` (step `marcador`) come out in English and Spanish, and switching language during a game updates the action bar and the drawn texts.
- **Risks:** widgets that cache text per frame; the death sentence needs whole templates, because Spanish "Te ha derrotado X con un golpe pesado" has another word order.

### L3b: hints, keys, nameplates and kill feed (UI-62, S)

- **Scope:** `HintCatalog`, hint toasts and log, the F1 help line, `UIKeyGlyph` key names (context `key`: "Shift" → "Mayús", "Enter" → "Intro"), nameplates (names raw, the level prefix translated), the kill feed with whole templates ("{killer} defeated {victim} with {cause}", "{victim} fell").
- **Main files:** `scripts/client/ui/hint_catalog.gd`, `hint_toasts.gd`, `hint_log.gd`, `ui_hint_bar.gd`, `ui_key_glyph.gd`, `nameplate.gd`, `nameplates.gd`, `war/kill_feed.gd`.
- **Done when:** `hud_reposo_campamento`, `placas_de_nombre_aliados` and a new F1 capture (`linea_de_ayuda_f1`) come out in English and Spanish, and an open hint follows a language change.

### L4a: protocol 8 wire format (TEC-57, M)

- **Scope (section 7):**
  - `ServerMessages` with `legacy.text`, `MessageBlock`, NOTICE v8 with CHAT, REJECT v8 (frozen prefix, no block before the version check, tolerant tail), the end of system `CHAT_MESSAGE`, `PROTOCOL_VERSION` 8 and the catalog hash;
  - every current sender sends `legacy.text` with its current text; the client renders it raw;
  - the platform changes of 7.7 (JSON, `main_test.go`, `platformtest`, env examples, CI jobs) and the deployment note;
  - a debug command, alongside the existing ones, that makes the server send a test notice and a system line, so the bench can capture them;
  - `networking.md`.
- **Main files:** `scripts/shared/net/server_messages.gd` (new), `net_messages.gd`, `net_protocol.gd`; `scripts/server/zone_server.gd`, `server_auth.gd`, `social/chat_router.gd`; `scripts/client/net_client.gd`, `online_main.gd`, `chat/chat_box.gd`, `bot_progress_scenario.gd`, `scripts/client/l10n/server_message_text.gd` (new); `platform/internal/gamedata/progression_rules.json`, `platform/cmd/eldmark-platform/main_test.go`, `platform/internal/platformtest/*.go`, `platform/deploy/*.env.example`; tests `test_net_messages*`, `test_net_loopback`, `test_net_processes`, `raw_enet_attacker.gd`, `test_progression_rules_export`, `test_server_message_text`.
- **Done when:** the Godot suite, "Plataforma" and "Plataforma e2e" pass at protocol 8; a v7 client gets a readable `REJECT VERSION`; captures of the test notice and the system line exist in English and Spanish. They show the same Spanish text in both, which is the "before" of L4b–L4d.
- **Risks:** fuzz and raw ENet tests; the deployment order.

### L4b: server operation, session and authentication (TEC-58, S)

- **Scope:** shutdown, maintenance, instance closed, save errors, session replaced, kicks; the REJECT blocks of 7.4 and the English operator texts (`reject_texts.gd`); `NetProtocol.result_text` and the `NameRules` text helpers leave shared code; `scripts/server/platform/ticket_auth_provider.gd` and `auth_outcome.gd`; tests `test_zone_server_platform`, `test_server_main` and the authentication tests.
- **Done when:** a maintenance notice and a forced "suspended until" rejection come out in English and Spanish, and the server tests of this area compare keys and parameters.

### L4c: party and chat router (TEC-59, S)

- **Scope:** `party_manager.gd` (~27 texts) and `chat_router.gd` (~9) become catalog entries; their tests compare keys and parameters (`test_party_manager`, 38 assertions, and `test_chat_router`).
- **Done when:** the chat preview (`interfaz --steps chat`, extended to render server messages from fixed blocks) shows party answers and chat router notices in English and Spanish.

### L4d: moderation, progress and `/unstuck` (TEC-60, S)

- **Scope:** the part of `moderation_service.gd` that players see (~29), `progress_service.gd` (bag full, character load) and the `/unstuck` replies; staff and console replies become `staff.reply`; `legacy.text` is retired and its id reserved.
- **Done when:** no message carries interface text except names and text written by people; a mute notice, an `/unstuck` cooldown and a full bag come out in English and Spanish.

### L5a: chat, commands and social (UI-63, M)

- **Scope:** the chat box and its local messages, the command parser with canonical ids and aliases (section 9), help, `ChatText` reasons as codes, the party invitation prompt and party frame (drawn text), the social menu; the server's command names become canonical (`command_registry.gd`, `moderation_service.gd`).
- **Main files:** `scripts/client/chat/*.gd`, `scripts/client/party/*.gd`, `scripts/client/social/social_menu.gd`, `scripts/shared/social/chat_text.gd`, `scripts/server/command_registry.gd`, `scripts/server/social/moderation_service.gd`; tests `test_chat_*`, `test_command_registry`.
- **Done when:** `chat_abierto_escribiendo`, `chat_con_mensajes`, `menu_social_g` and the chat preview with `/help` come out in English and Spanish, and `/help`, `/ayuda`, `/whisper` and `/susurrar` work in both languages.
- **Risks:** players who learned the Spanish short aliases (they keep them in Spanish); lines already in the chat stay in their language.

### L5b: war (UI-64, M)

- **Scope:** `WarEventText` (client) with the Hollow variants, war banners, capture panel (no more `capitalize()`), objective line and fraction bar (drawn text), boss bar, scoreboard, `RealmText` for owners ("Held by the Hollow"), fort names from the definition: `fortress_view.get_display_names()` feeds `hud.gd` and the world map with untranslated names and becomes a lookup of definitions translated by the consumers; the "Player %d" fallback of `player_directory.gd`. `war_hud.gd` has no text of its own, but it wires these widgets.
- **Main files:** `scripts/client/war/war_banners.gd`, `capture_panel.gd`, `objective_line.gd`, `fraction_bar.gd`, `boss_bar.gd`, `scoreboard_panel.gd`, `fortress_view.gd`, `war_hud.gd`, `player_directory.gd`, `scripts/shared/war/war_events.gd`, `realm_catalog.gd`; tests `test_capture_hud`, `test_scoreboard`, `test_war_events`.
- **Done when:** `marcador_tab`, `captura_fuerte_*`, `barra_de_jefe_*` and a war banner come out in English and Spanish.

### L6a: items and inventory (UI-65, M)

- **Scope:** `data/items/**` in English with their Spanish in `es.po`; `InventoryOps` and `Currency` return codes and numbers; inventory window, tooltips, rarities, split and destroy dialogs (the destroy question built from whole templates), character window (realm through `RealmText`).
- **Main files:** `data/items/**`, `scripts/shared/progression/inventory_ops.gd`, `currency.gd`, `scripts/client/inventory/*.gd`, `scripts/client/ui/ui_palette.gd`; tests `test_inventory_ops`, `test_inventory_window` (22 assertions).
- **Done when:** `inventario_i`, `personaje_c` and the gallery tooltips come out in English and Spanish.

### L6b: NPCs, forts and map (UI-66, M)

- **Scope:**
  - `data/npcs/*` and `data/fortresses/*` in English; NPC names from the definition when `npc_def_id != 0`; new definitions for the training dummy and the debug captain, so no NPC sends its name as text;
  - the world map, minimap ("N"), map legend and help, `zone_places.gd` and the landmark labels (8.1), with the names of 8.2;
  - the compass: `CARDINALS` as `# l10n ctx=compass` (English N, NE, E, SE, S, SW, W, NW; Spanish keeps N, NE, E, SE, S, SO, O, NO) and the heading label as a template;
  - world markers: `"{name} · {distance}"` as a template, `marker_source.gd` texts ("Gate", "Capture circle", "Fort") and marker ids that no longer come from labels;
  - `compass`, `world_markers`, `minimap` and `world_map` moved to `UIFonts.draw_text`.
- **Main files:** `data/npcs/*`, `data/fortresses/*`, `assets/maps/vado_gris_map.tres`, `scripts/client/map/*.gd`, `scripts/client/war/compass.gd`, `world_markers.gd`, `marker_source.gd`, `scripts/server/zone_server.gd` (the two NPCs); tests `test_world_map`, `test_zone_map`, `test_map_wave3`.
- **Done when:** the `mapa` area (`minimapa_*`, `brujula_*`, `mapa_m_*`, `hud_objetivo_lejos`) and `placas_de_nombre_fuerte` come out in English and Spanish, and the template holds every text field of `data/` and the map.
- **Risks:** IM Fell small capitals with labels that get longer; markers keyed by id instead of label.

### L7a: platform: account language, API messages and e-mails (TEC-61, M)

- **Scope:** the account stores a language (new migration), set at registration and refreshed at each login from the client's `Accept-Language` (sent by `PlatformApi`); the `message` of API errors becomes English (the client already translates by `code`); e-mail templates per language, with English fallback and dates per language.
- **Main files:** `platform/internal/accounts`, `internal/mail/mail.go`, `internal/httpx`, a new SQL migration, `scripts/client/platform/platform_api.gd`, Go tests and e2e.
- **Done when:** a registration from an English client sends the e-mail in English and one from a Spanish client sends exactly today's e-mail (the `LogSender` output of both is archived with the captures); the title screen shows a platform error in both languages.
- **Risks:** Go tests that compare Spanish messages (coordinate with TEC-52); existing accounts keep the default language until their next login.

### L7b: platform: legal texts, news and web pages (TEC-62, S)

- **Scope:** one legal file per language and version (`terms-1.en.md`, `terms-1.es.md`...), served by `/v1/legal/{kind}` according to the request; **Spanish is binding** and the English version opens with a notice that it is a translation; acceptance is still recorded by version; status news per language; the verify-e-mail and reset-password pages follow the browser's `Accept-Language`; the terms panel.
- **Main files:** `platform/legal/*`, the status and news handlers, `scripts/client/ui/terms_panel.gd`.
- **Done when:** the terms panel (`titulo_04_terminos`, fed from the real legal files) and the two web pages come out in English and Spanish.
- **Risks:** the wording of the translation notice, pending legal advice.

### L8a: developer text in English, client and tools (TEC-63, S)

- **Scope:** this is not localization: these literals become English. Client logs and `push_*`, the F3 panel, the FPS and DPS overlays (`hud.tscn` "FPS: 0", `net_debug_overlay`), the galleries and previews in `scripts/client/tools`, the bench output and the lines `run.py` waits for (`[driver] terminado`, `[strips] terminado`), and the tests that read them.
- **Done when:** `l10n_scan.py` needs no exception for client logs or overlays, and `panel_depuracion_f3` shows the same English in both languages.

### L8b: developer and staff text in English, server (TEC-64, M)

- **Scope:** server logs and `push_*`, catalog validation errors (`combat_catalog.gd` and the other catalogs), GM and console replies (`progress_commands.gd`, `command_registry.gd`) with the staff keywords of section 9, the log lines other tools parse (`run.py` waits for "escuchando en el puerto UDP" and "Alta de "; the load-test summaries read logs), and the ~60 test assertions that read logs. A new segment kind in `tools/i18n` for strings inside log calls, with the same proof that nothing else changed. Go log messages can go with TEC-52.
- **Done when:** no Spanish log or staff reply is left, the bench and the load test still find their lines, and a `/gm` reply shows the same English in both languages.

### Final review (UI-39, S)

- The scan covers all of `scripts/client`, `scenes` and `data`.
- `L10n.AUTO_FOLLOWS_OS` becomes `true` and the language options lose their "(Spanish)" and "(incomplete)" notes.
- The whole bench runs in English, Spanish and pseudo.
- Fixes: cut texts, overflowing buttons and tooltips, missing glyphs (the arrows, `▶ ◀` and `✕` become icons) and sentences that read like a translation.

## 15. Workflow for new text

1. Write the English text in code with `L10n`, following section 5.
2. Run `python -I tools/i18n/l10n_extract.py` and `python -I tools/i18n/l10n_po.py --update`.
3. Fill in the new `msgstr` entries in `locale/es.po`, with Poedit or by hand.
4. If the file is new, add it to `tools/i18n/l10n_scope.txt`; if it is a new screen, add it to `tests/test_l10n_screens.gd`.
5. Run `python -I tools/i18n/l10n_po.py --check` and `l10n_scan.py --check`, then commit the code, the template and `es.po` together.

Until L1b there is no template: L1a edits `es.po` by hand, and strict mode checks it.

## 16. Decisions and open points

### 16.1 Decided

- **Proper names:** descriptive names are translated and invented ones kept (8.2).
- **Chat aliases:** short aliases per client language; long names in both (9).
- **Legal texts:** Spanish binding, with an English translation that says so (L7b).
- **Rollout:** `auto` means Spanish until UI-39 (4.3).
- **Server export:** `locale/*` excluded (3).

### 16.2 Open

- **The `LineEdit` context menu** is engine text that stays English in both languages. Decide in L2a whether game fields disable it.
- **The exact English names** of the glossary (8.2) are reviewed in the increments that show them (L2b, L5b, L6b).
- **The wording of the translation notice** of the legal texts, pending legal advice (L7b).
