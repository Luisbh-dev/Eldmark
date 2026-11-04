class_name CombatIcons
extends RefCounted
## Iconos del combate (docs/habilidades.md, secciones 6.3 y 6.4; ART-12). Los dibujados de
## `assets/ui/icons/` ([GameIcon]: figura sobre el fondo de su categoría) se buscan por el [b]nombre[/b] del
## recurso (los ids del catálogo no son fijos): [method named] para acciones, habilidades, pociones y armas,
## y [method status_icon] para los efectos (las variantes pequeñas ya traen su fondo). Lo que no tiene dibujo
## sigue con el cuadro provisional con inicial ([PlaceholderIcon]) del color de su arma o del tipo de efecto.
## Se guardan en una caché: la barra de acciones pide los mismos iconos cada fotograma. Solo cliente.

const ICON_DIR: String = "res://assets/ui/icons/"
## Categoría (fondo) de cada figura: la misma tabla que `tools/ui/icons/glyphs.py`.
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
## Nombres de recurso que usan el dibujo de otro nombre.
const ALIASES: Dictionary[StringName, StringName] = {
	&"potion_regen": &"regen",
}
## Estados con variante pequeña (`small/<nombre>_14.png` y `_26.png`).
const SMALL_STATUSES: Array[StringName] = [
	&"bleed", &"regen", &"stun", &"slowed", &"knockback", &"downed", &"rooted",
]

## Color de cada arma (el de todas sus casillas con cuadro provisional).
const WEAPON_COLORS: Dictionary[StringName, Color] = {
	&"sword_shield": Color(0.33, 0.42, 0.6, 1.0),
	&"bow": Color(0.33, 0.52, 0.27, 1.0),
}
## Color de cada poción.
const CONSUMABLE_COLORS: Dictionary[StringName, Color] = {
	&"potion_health": Color(0.72, 0.16, 0.18, 1.0),
	&"potion_stamina": Color(0.5, 0.66, 0.16, 1.0),
}
## Color de cada efecto; los que no están aquí salen del color de su tipo.
const STATUS_COLORS: Dictionary[StringName, Color] = {
	&"bleed": Color(0.62, 0.1, 0.12, 1.0),
	&"slowed": Color(0.3, 0.42, 0.72, 1.0),
	&"rooted": Color(0.48, 0.36, 0.18, 1.0),
	&"potion_regen": Color(0.24, 0.58, 0.3, 1.0),
}
const HARMFUL_COLOR: Color = Color(0.55, 0.15, 0.2, 1.0)
const BENEFICIAL_COLOR: Color = Color(0.22, 0.52, 0.3, 1.0)
const DEFAULT_COLOR: Color = Color(0.4, 0.4, 0.45, 1.0)
## Color de las casillas que no son de un arma (esquiva).
const NEUTRAL_COLOR: Color = Color(0.42, 0.4, 0.36, 1.0)
## Color del icono de derribado de las placas.
const DOWNED_COLOR: Color = Color(0.78, 0.74, 0.92, 1.0)

static var _cache: Dictionary[String, PlaceholderIcon] = {}
static var _status_cache: Dictionary[String, Texture2D] = {}
static var _named_cache: Dictionary[StringName, Texture2D] = {}


## Nombre del dibujo de [param resource_name] (con los alias aplicados).
static func figure_name(resource_name: StringName) -> StringName:
	return ALIASES.get(resource_name, resource_name)


## true si hay un dibujo propio para [param resource_name].
static func has_figure(resource_name: StringName) -> bool:
	return CATEGORIES.has(figure_name(resource_name))


## El icono dibujado de [param resource_name] (figura sobre el fondo de su categoría), o null si no hay
## dibujo. De la caché.
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


## El icono de [param resource_name] o, si no tiene dibujo, el cuadro con la inicial de
## [param fallback_text] sobre [param fallback_fill].
static func named_or_letter(resource_name: StringName, fallback_text: String,
		fallback_fill: Color) -> Texture2D:
	var drawn: Texture2D = named(resource_name)
	return drawn if drawn != null else icon(fallback_text, fallback_fill)


## Color del arma [param weapon_id] del catálogo.
static func weapon_color(weapon_id: int) -> Color:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null:
		return DEFAULT_COLOR
	return WEAPON_COLORS.get(weapon.name, DEFAULT_COLOR)


## Icono con la inicial de [param text] y el color [param fill] (de la caché).
static func icon(text: String, fill: Color) -> PlaceholderIcon:
	var key: String = "%s|%s" % [text.left(1).to_upper(), fill.to_html()]
	var cached: PlaceholderIcon = _cache.get(key)
	if cached == null:
		cached = PlaceholderIcon.make(text, fill)
		_cache[key] = cached
	return cached


## Icono del arma [param weapon_id] (`weapon_<nombre>`): la casilla del cambio de arma.
static func weapon_icon(weapon_id: int) -> Texture2D:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	var fallback: Color = weapon_color(weapon_id)
	if weapon == null:
		return icon("", fallback)
	return named_or_letter(StringName("weapon_%s" % weapon.name), CombatText.weapon_title(weapon_id), fallback)


## Icono de la habilidad [param ability_id]: su dibujo (por el nombre del recurso) o, sin él, la inicial de
## su título con el color de su arma o de la poción.
static func ability_icon(ability_id: int) -> Texture2D:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	if ability == null:
		return null
	var fill: Color = CONSUMABLE_COLORS.get(ability.name, weapon_color(ability.weapon_id))
	return named_or_letter(ability.name, CombatText.ability_title(ability_id), fill)


## Color del efecto [param status_id]: el suyo o el de su tipo (perjudicial o beneficioso).
static func status_color(status_id: int) -> Color:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null:
		return HARMFUL_COLOR
	return STATUS_COLORS.get(status.name, HARMFUL_COLOR if status.is_harmful() else BENEFICIAL_COLOR)


## Icono del efecto [param status_id]. Con [param pixels] de 14 o 26 sale la variante pequeña dibujada a
## su medida exacta (ya trae su fondo); con otro valor o sin ella, el icono grande o, si tampoco hay, la
## inicial de su título con su color.
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
