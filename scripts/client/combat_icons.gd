class_name CombatIcons
extends RefCounted
## Combat icons (docs/habilidades.md, sections 6.3 and 6.4; ART-12). The drawn ones in
## `assets/ui/icons/` ([GameIcon]: figure on the background of its category) are looked up by the [b]name[/b] of the
## resource (the catalog ids are not fixed): [method named] for actions, abilities, potions and weapons,
## and [method status_icon] for effects (the small variants already come with their background). What has no drawing
## keeps the provisional box with an initial ([PlaceholderIcon]) in the color of its weapon or of the effect type.
## They are kept in a cache: the action bar asks for the same icons every frame. Client only.

const ICON_DIR: String = "res://assets/ui/icons/"
## Category (background) of each figure: the same table as `tools/ui/icons/glyphs.py`.
const CATEGORIES: Dictionary[StringName, StringName] = {
	&"sword_light": &"ataque", &"sword_heavy": &"ataque", &"bow_quick": &"ataque", &"bow_drawn": &"ataque",
	&"block": &"defensa", &"dodge": &"defensa",
	&"shield_bash": &"habilidad", &"shield_rush": &"habilidad", &"shield_wall": &"habilidad",
	&"bow_volley": &"habilidad", &"bow_slowing_shot": &"habilidad", &"bow_evasive_shot": &"habilidad",
	&"potion_health": &"consumible", &"potion_stamina": &"consumible",
	&"swap_weapon": &"mundo", &"weapon_sword_shield": &"mundo", &"weapon_bow": &"mundo",
	&"interact": &"mundo", &"fort": &"mundo", &"gate": &"mundo", &"camp": &"mundo",
	&"bleed": &"estado_malo", &"stun": &"estado_malo", &"slowed": &"estado_malo",
	&"knockback": &"estado_malo", &"downed": &"estado_malo", &"rooted": &"estado_malo",
	&"regen": &"estado_bueno",
}
## Resource names that use the drawing of another name.
const ALIASES: Dictionary[StringName, StringName] = {
	&"potion_regen": &"regen",
}
## Statuses with a small variant (`small/<nombre>_14.png` and `_26.png`).
const SMALL_STATUSES: Array[StringName] = [
	&"bleed", &"regen", &"stun", &"slowed", &"knockback", &"downed", &"rooted",
]

## Color of each weapon (that of all its slots with a provisional box).
const WEAPON_COLORS: Dictionary[StringName, Color] = {
	&"sword_shield": Color(0.33, 0.42, 0.6, 1.0),
	&"bow": Color(0.33, 0.52, 0.27, 1.0),
}
## Color of each potion.
const CONSUMABLE_COLORS: Dictionary[StringName, Color] = {
	&"potion_health": Color(0.72, 0.16, 0.18, 1.0),
	&"potion_stamina": Color(0.5, 0.66, 0.16, 1.0),
}
## Color of each effect; those not listed here take the color of their type.
const STATUS_COLORS: Dictionary[StringName, Color] = {
	&"bleed": Color(0.62, 0.1, 0.12, 1.0),
	&"slowed": Color(0.3, 0.42, 0.72, 1.0),
	&"rooted": Color(0.48, 0.36, 0.18, 1.0),
	&"potion_regen": Color(0.24, 0.58, 0.3, 1.0),
}
const HARMFUL_COLOR: Color = Color(0.55, 0.15, 0.2, 1.0)
const BENEFICIAL_COLOR: Color = Color(0.22, 0.52, 0.3, 1.0)
const DEFAULT_COLOR: Color = Color(0.4, 0.4, 0.45, 1.0)
## Color of the slots that do not belong to a weapon (dodge).
const NEUTRAL_COLOR: Color = Color(0.42, 0.4, 0.36, 1.0)
## Color of the knocked-down icon on the nameplates.
const DOWNED_COLOR: Color = Color(0.78, 0.74, 0.92, 1.0)

static var _cache: Dictionary[String, PlaceholderIcon] = {}
static var _status_cache: Dictionary[String, Texture2D] = {}
static var _named_cache: Dictionary[StringName, Texture2D] = {}


## Name of the drawing of [param resource_name] (with the aliases applied).
static func figure_name(resource_name: StringName) -> StringName:
	return ALIASES.get(resource_name, resource_name)


## true if there is a drawing of its own for [param resource_name].
static func has_figure(resource_name: StringName) -> bool:
	return CATEGORIES.has(figure_name(resource_name))


## The drawn icon of [param resource_name] (figure on the background of its category), or null if there is no
## drawing. From the cache.
static func named(resource_name: StringName) -> Texture2D:
	var key: StringName = figure_name(resource_name)
	if _named_cache.has(key):
		return _named_cache[key]
	var icon: Texture2D = null
	if CATEGORIES.has(key):
		var figure_path: String = "%s%s.png" % [ICON_DIR, key]
		var background_path: String = "%sbackgrounds/%s.png" % [ICON_DIR, CATEGORIES[key]]
		if ResourceLoader.exists(figure_path):
			var background: Texture2D = null
			if ResourceLoader.exists(background_path):
				background = load(background_path) as Texture2D
			icon = GameIcon.make(load(figure_path) as Texture2D, background)
	_named_cache[key] = icon
	return icon


## The icon of [param resource_name] or, if it has no drawing, the box with the initial of
## [param fallback_text] on [param fallback_fill].
static func named_or_letter(resource_name: StringName, fallback_text: String,
		fallback_fill: Color) -> Texture2D:
	var drawn: Texture2D = named(resource_name)
	return drawn if drawn != null else icon(fallback_text, fallback_fill)


## Color of the catalog weapon [param weapon_id].
static func weapon_color(weapon_id: int) -> Color:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null:
		return DEFAULT_COLOR
	return WEAPON_COLORS.get(weapon.name, DEFAULT_COLOR)


## Icon with the initial of [param text] and the color [param fill] (from the cache).
static func icon(text: String, fill: Color) -> PlaceholderIcon:
	var key: String = "%s|%s" % [text.left(1).to_upper(), fill.to_html()]
	var cached: PlaceholderIcon = _cache.get(key)
	if cached == null:
		cached = PlaceholderIcon.make(text, fill)
		_cache[key] = cached
	return cached


## Icon of the weapon [param weapon_id] (`weapon_<nombre>`): the weapon swap slot.
static func weapon_icon(weapon_id: int) -> Texture2D:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	var fallback: Color = weapon_color(weapon_id)
	if weapon == null:
		return icon("", fallback)
	return named_or_letter(StringName("weapon_%s" % weapon.name), CombatText.weapon_title(weapon_id), fallback)


## Icon of the ability [param ability_id]: its drawing (by resource name) or, without it, the initial of
## its title with the color of its weapon or of the potion.
static func ability_icon(ability_id: int) -> Texture2D:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	if ability == null:
		return null
	var fill: Color = CONSUMABLE_COLORS.get(ability.name, weapon_color(ability.weapon_id))
	return named_or_letter(ability.name, CombatText.ability_title(ability_id), fill)


## Color of the effect [param status_id]: its own or that of its type (harmful or beneficial).
static func status_color(status_id: int) -> Color:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null:
		return HARMFUL_COLOR
	return STATUS_COLORS.get(status.name, HARMFUL_COLOR if status.is_harmful() else BENEFICIAL_COLOR)


## Icon of the effect [param status_id]. With [param pixels] of 14 or 26 the small variant drawn at
## its exact size comes out (it already has its background); with another value or without it, the large icon or, if there is none either, the
## initial of its title with its color.
static func status_icon(status_id: int, pixels: int = 0) -> Texture2D:
	var key: String = "%d|%d" % [status_id, pixels]
	if _status_cache.has(key):
		return _status_cache[key]
	var status: StatusTicks = CombatCatalog.status(status_id)
	var result: Texture2D = null
	if status != null:
		var figure: StringName = figure_name(status.name)
		if (pixels == 14 or pixels == 26) and SMALL_STATUSES.has(figure):
			var path: String = "%ssmall/%s_%d.png" % [ICON_DIR, figure, pixels]
			if ResourceLoader.exists(path):
				result = load(path) as Texture2D
		if result == null:
			result = named(status.name)
	if result == null:
		result = icon(CombatText.status_title(status_id), status_color(status_id))
	_status_cache[key] = result
	return result
