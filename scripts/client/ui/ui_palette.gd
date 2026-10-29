class_name UIPalette
extends RefCounted
## Paleta de la interfaz (UI-02): los colores que usan el tema ([UIThemeBuilder]), los componentes
## comunes y el HUD.
## [br][br]
## Estilo (decisión del backlog): minimalista oscuro y translúcido, con remates de metal y piedra de
## Eld y acentos del color del bando. Lo fuerte (el color) queda para los bandos, que salen de
## [RealmCatalog] (mundo.md, «Colores de bando»); el resto de la interfaz es neutro, y el acento
## neutro son las Brasas de Eld.
## [br][br]
## Solo cliente. Todo son constantes y funciones estáticas, sin estado.

## Rarezas de los objetos (borde y contador de las casillas, tooltips). Se ordenan de peor a mejor.
enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

# --- Superficies ------------------------------------------------------------------------------

## Fondo de un panel: casi negro azulado y translúcido, para que se vea el mundo detrás.
const PANEL_BG: Color = Color(0.055, 0.06, 0.075, 0.84)
## Fondo de lo hundido dentro de un panel (campos de texto, huecos de casilla, pistas de barra).
const INSET_BG: Color = Color(0.025, 0.028, 0.036, 0.9)
## Fondo de una ventana: más opaco que el de un panel de juego.
const WINDOW_BG: Color = Color(0.06, 0.065, 0.082, 0.96)
## Fondo de un botón en reposo y con el ratón encima.
const BUTTON_BG: Color = Color(0.1, 0.108, 0.132, 0.92)
const BUTTON_BG_HOVER: Color = Color(0.15, 0.158, 0.19, 0.95)
const BUTTON_BG_PRESSED: Color = Color(0.05, 0.054, 0.068, 0.96)
const BUTTON_BG_DISABLED: Color = Color(0.07, 0.074, 0.09, 0.7)
## Velo que atenúa el juego detrás de un diálogo modal.
const MODAL_DIM: Color = Color(0.0, 0.0, 0.0, 0.55)
## Panel de depuración (el del HUD): el de antes de UI-02, un poco más translúcido que un panel.
const DEBUG_BG: Color = Color(0.05, 0.06, 0.08, 0.62)

# --- Remates (metal y piedra) -----------------------------------------------------------------

## Borde de metal oscuro y de piedra clara.
const BORDER: Color = Color(0.3, 0.285, 0.26, 0.95)
const BORDER_LIGHT: Color = Color(0.5, 0.47, 0.42, 1.0)
const BORDER_DIM: Color = Color(0.2, 0.195, 0.185, 0.9)

# --- Texto ------------------------------------------------------------------------------------

const TEXT: Color = Color(0.91, 0.9, 0.88, 1.0)
const TEXT_DIM: Color = Color(0.64, 0.62, 0.58, 1.0)
const TEXT_DISABLED: Color = Color(0.42, 0.41, 0.39, 1.0)
## Títulos: hueso cálido.
const TITLE: Color = Color(0.85, 0.79, 0.64, 1.0)
const OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)

# --- Acentos y estados ------------------------------------------------------------------------

## Acento neutro (sin bando): las Brasas de Eld.
const ACCENT: Color = Color(0.88, 0.51, 0.18, 1.0)
const HEALTH: Color = Color(0.78, 0.13, 0.15, 1.0)
const STAMINA: Color = Color(0.58, 0.82, 0.3, 1.0)
const SUCCESS: Color = Color(0.42, 0.78, 0.4, 1.0)
const WARNING: Color = Color(1.0, 0.72, 0.4, 1.0)
const DANGER: Color = Color(0.9, 0.3, 0.26, 1.0)

## Color de cada rareza, en el orden de [enum Rarity]: gris, verde, azul, morado y naranja.
const RARITY_COLORS: Array[Color] = [
	Color(0.66, 0.66, 0.66, 1.0), Color(0.37, 0.72, 0.35, 1.0), Color(0.3, 0.56, 0.84, 1.0),
	Color(0.64, 0.37, 0.82, 1.0), Color(0.88, 0.54, 0.18, 1.0),
]
## Nombre en español de cada rareza, en el mismo orden.
const RARITY_NAMES: Array[String] = ["Común", "Poco común", "Raro", "Épico", "Legendario"]


# --- Bandos -----------------------------------------------------------------------------------

## Color de bando de [param faction_id] (los tres reinos y los Huecos), de [RealmCatalog].
## Blanco si el bando no existe.
static func faction_color(faction_id: StringName) -> Color:
	return RealmCatalog.color_of(faction_id)


## Color del bando con código de red [param code] (1 a 3 los reinos, 0 los Huecos).
static func faction_color_of_code(code: int) -> Color:
	return RealmCatalog.color_of(RealmCatalog.id_of_code(code))


## Acento para un bando: su color si existe y, si no, el acento neutro.
static func accent_for(faction_id: StringName) -> Color:
	return RealmCatalog.color_of(faction_id) if RealmCatalog.has_faction(faction_id) else ACCENT


## El color de bando oscurecido para usarlo como borde o fondo de acento sin que grite.
static func faction_border(faction_id: StringName) -> Color:
	var color: Color = accent_for(faction_id)
	return Color(color.r * 0.8, color.g * 0.8, color.b * 0.8, 0.95)


## Ruta del emblema del bando (puede no existir hasta que lo aporte el arte; ver [method
## load_emblem]).
static func emblem_path(faction_id: StringName) -> String:
	return RealmCatalog.emblem_path(faction_id)


## Carga el emblema de [param faction_id]; null si el bando no existe o su archivo todavía no está.
static func load_emblem(faction_id: StringName) -> Texture2D:
	var path: String = RealmCatalog.emblem_path(faction_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# --- Rarezas ----------------------------------------------------------------------------------

## Color de la rareza [param rarity] (un valor de [enum Rarity]); el de común si se sale del rango.
static func rarity_color(rarity: int) -> Color:
	if rarity < 0 or rarity >= RARITY_COLORS.size():
		return RARITY_COLORS[Rarity.COMMON]
	return RARITY_COLORS[rarity]


## Nombre en español de la rareza [param rarity]; «Común» si se sale del rango.
static func rarity_name(rarity: int) -> String:
	if rarity < 0 or rarity >= RARITY_NAMES.size():
		return RARITY_NAMES[Rarity.COMMON]
	return RARITY_NAMES[rarity]


# --- Utilidades -------------------------------------------------------------------------------

## [param color] con la opacidad [param alpha].
static func with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)


## Luminancia relativa (0 a 1) de [param color], para decidir si el texto encima debe ser claro u
## oscuro.
static func luminance(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


## Color de texto legible sobre [param background]: el claro de la paleta sobre fondos oscuros y casi
## negro sobre los claros.
static func text_on(background: Color) -> Color:
	return TEXT if luminance(background) < 0.55 else Color(0.07, 0.07, 0.08, 1.0)
