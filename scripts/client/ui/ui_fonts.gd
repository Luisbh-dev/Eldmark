class_name UIFonts
extends RefCounted
## UI fonts (UI-02): two OFL families across the whole client. Cinzel for titles and place
## labels, Noto Sans for text, numbers and nameplates; IM Fell English SC remains available for
## the map labels. The files are in [code]assets/fonts/[/code] (author and license in
## [code]assets/LICENCIAS.md[/code]).
## [br][br]
## All code that draws text with [method CanvasItem.draw_string] asks for its font here instead of using the
## engine's ("fallback_font" of ThemeDB, which a test forbids in [code]scripts/client[/code]).
## Fonts are loaded once and cached. Client only.

const BODY_PATH: String = "res://assets/fonts/NotoSans-Variable.ttf"
const TITLE_PATH: String = "res://assets/fonts/Cinzel-Variable.ttf"
const MAP_PATH: String = "res://assets/fonts/IMFellEnglishSC-Regular.ttf"

## Weight (wght axis) of the "semibold" text for numbers and nameplates, which are read over the world.
const SEMIBOLD_WEIGHT: int = 600
const BOLD_WEIGHT: int = 700

static var _cache: Dictionary[String, Font] = {}


## Regular Noto Sans: ordinary text.
static func body() -> Font:
	return _load(BODY_PATH)


## Semibold Noto Sans: numbers, nameplates and small labels over the world.
static func body_semibold() -> Font:
	return _variation(BODY_PATH, SEMIBOLD_WEIGHT)


## Bold Noto Sans.
static func body_bold() -> Font:
	return _variation(BODY_PATH, BOLD_WEIGHT)


## Cinzel: titles, boss names, notices.
static func title() -> Font:
	return _load(TITLE_PATH)


## Bold Cinzel (the big notices).
static func title_bold() -> Font:
	return _variation(TITLE_PATH, BOLD_WEIGHT)


## IM Fell English SC: place labels on the map.
static func map_label() -> Font:
	return _load(MAP_PATH)


static func _load(path: String) -> Font:
	var cached: Font = _cache.get(path)
	if cached != null:
		return cached
	var font: Font = load(path) as Font
	if font == null:
		# Without the file (an export that does not include it) the theme's default font is used.
		font = ThemeDB.get_default_theme().get_default_font()
	_cache[path] = font
	return font


static func _variation(path: String, weight: int) -> Font:
	var key: String = "%s#%d" % [path, weight]
	var cached: Font = _cache.get(key)
	if cached != null:
		return cached
	var base: Font = _load(path)
	var font: Font = base
	if base is FontFile:
		var variation := FontVariation.new()
		variation.base_font = base
		variation.variation_opentype = {&"wght": weight}
		font = variation
	_cache[key] = font
	return font
