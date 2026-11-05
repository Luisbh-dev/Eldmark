class_name UIPalette
extends RefCounted
## UI palette (UI-02): the colors used by the theme ([UIThemeBuilder]), the common
## components and the HUD.
## [br][br]
## Style (backlog decision): dark, minimalist and translucent, with metal and Eld stone
## trim and accents in the faction color. The loud part (color) is left to the factions, which come from
## [RealmCatalog] (world.md, "Colores de bando", i.e. "Faction colors"); the rest of the interface is neutral, and the neutral
## accent is the Embers of Eld.
## [br][br]
## Client only. Everything is constants and static functions, with no state.

## Item rarities (slot border and counter, tooltips). Ordered from worst to best.
enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

# --- Surfaces ---------------------------------------------------------------------------------

## Panel background: near-black bluish and translucent, so the world shows behind it.
const PANEL_BG: Color = Color(0.055, 0.06, 0.075, 0.84)
## Background of what is recessed inside a panel (text fields, slot wells, bar tracks).
const INSET_BG: Color = Color(0.025, 0.028, 0.036, 0.9)
## Window background: more opaque than a game panel's.
const WINDOW_BG: Color = Color(0.06, 0.065, 0.082, 0.96)
## Background of a button at rest and with the mouse over it.
const BUTTON_BG: Color = Color(0.1, 0.108, 0.132, 0.92)
const BUTTON_BG_HOVER: Color = Color(0.15, 0.158, 0.19, 0.95)
const BUTTON_BG_PRESSED: Color = Color(0.05, 0.054, 0.068, 0.96)
const BUTTON_BG_DISABLED: Color = Color(0.07, 0.074, 0.09, 0.7)
## Veil that dims the game behind a modal dialog.
const MODAL_DIM: Color = Color(0.0, 0.0, 0.0, 0.55)
## Debug panel (the HUD's): the pre-UI-02 one, slightly more translucent than a panel.
const DEBUG_BG: Color = Color(0.05, 0.06, 0.08, 0.62)

# --- Trim (metal and stone) -------------------------------------------------------------------

## Border of dark metal and of light stone.
const BORDER: Color = Color(0.3, 0.285, 0.26, 0.95)
const BORDER_LIGHT: Color = Color(0.5, 0.47, 0.42, 1.0)
const BORDER_DIM: Color = Color(0.2, 0.195, 0.185, 0.9)

# --- Text -------------------------------------------------------------------------------------

const TEXT: Color = Color(0.91, 0.9, 0.88, 1.0)
const TEXT_DIM: Color = Color(0.64, 0.62, 0.58, 1.0)
const TEXT_DISABLED: Color = Color(0.42, 0.41, 0.39, 1.0)
## Titles: warm bone.
const TITLE: Color = Color(0.85, 0.79, 0.64, 1.0)
const OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)

# --- Accents and states -----------------------------------------------------------------------

## Neutral accent (no faction): the Embers of Eld.
const ACCENT: Color = Color(0.88, 0.51, 0.18, 1.0)
const HEALTH: Color = Color(0.78, 0.13, 0.15, 1.0)
const STAMINA: Color = Color(0.58, 0.82, 0.3, 1.0)
const SUCCESS: Color = Color(0.42, 0.78, 0.4, 1.0)
const WARNING: Color = Color(1.0, 0.72, 0.4, 1.0)
const DANGER: Color = Color(0.9, 0.3, 0.26, 1.0)

# --- Combat semantic palette (UI-50): one color per meaning -----------------------------------

## Danger from NPCs (the telegraph of their strikes): amber with a lighter border. Red is kept for damage
## taken and health; this way "it is about to hit you" and "you have been hit" are not confused.
const TELEGRAPH: Color = Color(1.0, 0.6, 0.08, 1.0)
const TELEGRAPH_EDGE: Color = Color(1.0, 0.84, 0.35, 1.0)
## Health bar of an ally and of an enemy on nameplates.
const ALLY: Color = Color(0.36, 0.8, 0.38, 1.0)
const ENEMY: Color = Color(0.86, 0.2, 0.18, 1.0)
## Boss bar.
const BOSS: Color = Color(0.72, 0.1, 0.12, 1.0)
## Own damage text (cream) and damage taken (red).
const DAMAGE_DEALT: Color = Color(1.0, 0.95, 0.75, 1.0)
const DAMAGE_TAKEN: Color = Color(1.0, 0.28, 0.28, 1.0)

## Color of each rarity, in the order of [enum Rarity]: gray, green, blue, purple and orange.
const RARITY_COLORS: Array[Color] = [
	Color(0.66, 0.66, 0.66, 1.0), Color(0.37, 0.72, 0.35, 1.0), Color(0.3, 0.56, 0.84, 1.0),
	Color(0.64, 0.37, 0.82, 1.0), Color(0.88, 0.54, 0.18, 1.0),
]
## Spanish name of each rarity, in the same order.
const RARITY_NAMES: Array[String] = ["Común", "Poco común", "Raro", "Épico", "Legendario"]


# --- Factions ---------------------------------------------------------------------------------

## Faction color of [param faction_id] (the three realms and the Hollow), from [RealmCatalog].
## White if the faction does not exist.
static func faction_color(faction_id: StringName) -> Color:
	return RealmCatalog.color_of(faction_id)


## Color of the faction with network code [param code] (1 to 3 the realms, 0 the Hollow).
static func faction_color_of_code(code: int) -> Color:
	return RealmCatalog.color_of(RealmCatalog.id_of_code(code))


## Accent for a faction: its color if it exists and, if not, the neutral accent.
static func accent_for(faction_id: StringName) -> Color:
	return RealmCatalog.color_of(faction_id) if RealmCatalog.has_faction(faction_id) else ACCENT


## The faction color darkened to use as a border or accent background without it shouting.
static func faction_border(faction_id: StringName) -> Color:
	var color: Color = accent_for(faction_id)
	return Color(color.r * 0.8, color.g * 0.8, color.b * 0.8, 0.95)


## Path of the faction's emblem (it may not exist until the art provides it; see [method
## load_emblem]).
static func emblem_path(faction_id: StringName) -> String:
	return RealmCatalog.emblem_path(faction_id)


## Loads the emblem of [param faction_id]; null if the faction does not exist or its file is not there yet.
static func load_emblem(faction_id: StringName) -> Texture2D:
	var path: String = RealmCatalog.emblem_path(faction_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# --- Rarities ---------------------------------------------------------------------------------

## Color of rarity [param rarity] (a value of [enum Rarity]); the common one if out of range.
static func rarity_color(rarity: int) -> Color:
	if rarity < 0 or rarity >= RARITY_COLORS.size():
		return RARITY_COLORS[Rarity.COMMON]
	return RARITY_COLORS[rarity]


## Spanish name of rarity [param rarity]; "Común" ("Common") if out of range.
static func rarity_name(rarity: int) -> String:
	if rarity < 0 or rarity >= RARITY_NAMES.size():
		return RARITY_NAMES[Rarity.COMMON]
	return RARITY_NAMES[rarity]


# --- Utilities --------------------------------------------------------------------------------

## [param color] with opacity [param alpha].
static func with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)


## Relative luminance (0 to 1) of [param color], to decide whether the text on top should be light or
## dark.
static func luminance(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


## Readable text color over [param background]: the palette's light one over dark backgrounds and near
## black over light ones.
static func text_on(background: Color) -> Color:
	return TEXT if luminance(background) < 0.55 else Color(0.07, 0.07, 0.08, 1.0)
