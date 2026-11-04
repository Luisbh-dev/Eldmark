class_name UIFonts
extends RefCounted
## Fuentes de la interfaz (UI-02): dos familias OFL en todo el cliente. Cinzel para títulos y rótulos de
## lugares, Noto Sans para el texto, los números y las placas; IM Fell English SC queda disponible para
## los rótulos del mapa. Los archivos están en [code]assets/fonts/[/code] (autor y licencia en
## [code]assets/LICENCIAS.md[/code]).
## [br][br]
## Todo código que dibuja texto con [method CanvasItem.draw_string] pide aquí su fuente en vez de usar la
## del motor (la «fallback_font» de ThemeDB, que una prueba prohíbe en [code]scripts/client[/code]).
## Las fuentes se cargan una vez y se guardan. Solo cliente.

const BODY_PATH: String = "res://assets/fonts/NotoSans-Variable.ttf"
const TITLE_PATH: String = "res://assets/fonts/Cinzel-Variable.ttf"
const MAP_PATH: String = "res://assets/fonts/IMFellEnglishSC-Regular.ttf"

## Grosor (eje wght) del texto «seminegrita» de números y placas, que se leen sobre el mundo.
const SEMIBOLD_WEIGHT: int = 600
const BOLD_WEIGHT: int = 700

static var _cache: Dictionary[String, Font] = {}


## Noto Sans normal: texto corriente.
static func body() -> Font:
	return _load(BODY_PATH)


## Noto Sans en seminegrita: números, placas y rótulos pequeños sobre el mundo.
static func body_semibold() -> Font:
	return _variation(BODY_PATH, SEMIBOLD_WEIGHT)


## Noto Sans en negrita.
static func body_bold() -> Font:
	return _variation(BODY_PATH, BOLD_WEIGHT)


## Cinzel: títulos, nombres de jefe, avisos.
static func title() -> Font:
	return _load(TITLE_PATH)


## Cinzel en negrita (los avisos grandes).
static func title_bold() -> Font:
	return _variation(TITLE_PATH, BOLD_WEIGHT)


## IM Fell English SC: rótulos de lugares del mapa.
static func map_label() -> Font:
	return _load(MAP_PATH)


static func _load(path: String) -> Font:
	var cached: Font = _cache.get(path)
	if cached != null:
		return cached
	var font: Font = load(path) as Font
	if font == null:
		# Sin el archivo (una exportación que no lo incluya) se usa la fuente por defecto del tema.
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
