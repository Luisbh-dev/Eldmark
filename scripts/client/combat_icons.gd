class_name CombatIcons
extends RefCounted
## Iconos provisionales del combate (docs/habilidades.md, secciones 6.3 y 6.4; hasta ART-12): cuadros
## ([PlaceholderIcon]) con la inicial de la acción, la habilidad o el efecto y el color de su arma o del
## tipo de efecto. Los colores van por el [b]nombre[/b] del recurso (los ids del catálogo no son fijos).
## Se guardan en una caché: la barra de acciones pide los mismos iconos cada fotograma. Solo cliente.

## Color de cada arma (el de todas sus casillas).
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
const DOWNED_COLOR: Color = Color(0.85, 0.45, 0.1, 1.0)

static var _cache: Dictionary[String, PlaceholderIcon] = {}
static var _status_cache: Dictionary[int, PlaceholderIcon] = {}


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


## Icono de una acción del arma [param weapon_id] (ataque, bloqueo...) con la inicial de [param title].
static func action_icon(title: String, weapon_id: int) -> PlaceholderIcon:
	return icon(title, weapon_color(weapon_id))


## Icono del arma [param weapon_id] (su inicial): la casilla del cambio de arma.
static func weapon_icon(weapon_id: int) -> PlaceholderIcon:
	return icon(CombatText.weapon_title(weapon_id), weapon_color(weapon_id))


## Icono de la habilidad [param ability_id]: inicial de su título; color de su arma o de la poción.
static func ability_icon(ability_id: int) -> PlaceholderIcon:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	if ability == null:
		return null
	var fill: Color = CONSUMABLE_COLORS.get(ability.name, weapon_color(ability.weapon_id))
	return icon(CombatText.ability_title(ability_id), fill)


## Color del efecto [param status_id]: el suyo o el de su tipo (perjudicial o beneficioso).
static func status_color(status_id: int) -> Color:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null:
		return HARMFUL_COLOR
	return STATUS_COLORS.get(status.name, HARMFUL_COLOR if status.is_harmful() else BENEFICIAL_COLOR)


## Icono del efecto [param status_id]: inicial de su título y su color.
static func status_icon(status_id: int) -> PlaceholderIcon:
	var cached: PlaceholderIcon = _status_cache.get(status_id)
	if cached == null:
		cached = icon(CombatText.status_title(status_id), status_color(status_id))
		_status_cache[status_id] = cached
	return cached
