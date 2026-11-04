class_name CombatText
extends RefCounted
## Spanish combat texts for the UI (death screen, kill feed, action bar,
## status icons, knockdown notices, template selector): what each attack, ability, effect,
## weapon and template in the catalog is called, and the "who defeated you and with what" sentence.
## [br][br]
## Since protocol 6 events carry a [b]source[/b] ([CombatSource]: attack, ability, effect,
## execution or bleed-out) instead of an attack id; [method source_label] names it. Attacks
## keep their number (their source is their id), so [method attack_label] still works for them.
## [br][br]
## The tables go by the resource [b]name[/b] (the [code]id[/code] of its [code].tres[/code]): the
## catalog's numeric ids are not fixed (docs/habilidades.md, section 2.2).

## Name of each catalog attack ([member AttackDefinition.id]) as read after "con" (with).
const ATTACK_LABELS: Dictionary[StringName, String] = {
	&"sword_light_1": "un tajo ligero",
	&"sword_light_2": "un tajo ligero",
	&"sword_light_3": "un tajo ligero final",
	&"sword_heavy": "un golpe pesado",
	&"bow_quick": "un disparo rápido",
	&"bow_drawn": "un disparo tensado",
}
## Name of each ability (and potion) as read after "con" (with).
const ABILITY_LABELS: Dictionary[StringName, String] = {
	&"shield_bash": "un golpe de escudo",
	&"shield_rush": "una embestida",
	&"shield_wall": "el muro de escudos",
	&"bow_volley": "un abanico de flechas",
	&"bow_slowing_shot": "una flecha lastrante",
	&"bow_evasive_shot": "un salto atrás con disparo",
	&"potion_health": "una poción de vida",
	&"potion_stamina": "una poción de resistencia",
}
## Name of each effect as read after "con" (with) (the damage of its pulses).
const STATUS_LABELS: Dictionary[StringName, String] = {
	&"bleed": "un sangrado",
	&"slowed": "una ralentización",
	&"rooted": "un enraizamiento",
	&"potion_regen": "una curación",
}
## Title of each ability (action bar and its tooltip).
const ABILITY_TITLES: Dictionary[StringName, String] = {
	&"shield_bash": "Golpe de escudo",
	&"shield_rush": "Embestida",
	&"shield_wall": "Muro de escudos",
	&"bow_volley": "Abanico",
	&"bow_slowing_shot": "Flecha lastrante",
	&"bow_evasive_shot": "Salto atrás con disparo",
	&"potion_health": "Poción de vida",
	&"potion_stamina": "Poción de resistencia",
}
## Short description of each ability for the tooltip.
const ABILITY_DESCRIPTIONS: Dictionary[StringName, String] = {
	&"shield_bash": "Golpe imbloqueable que aturde al que tienes delante.",
	&"shield_rush": "Avanzas 6 m y empujas a quien encuentres.",
	&"shield_wall": "Mantén para bloquear de frente en un arco amplio y parar las flechas de los que tienes detrás.",
	&"bow_volley": "Tres flechas en abanico.",
	&"bow_slowing_shot": "Una flecha que ralentiza al blanco.",
	&"bow_evasive_shot": "Saltas hacia atrás y disparas.",
	&"potion_health": "Recupera vida durante unos segundos. Un golpe mientras bebes la interrumpe sin gastarla.",
	&"potion_stamina": "Recupera resistencia al acabar de beber. Un golpe mientras bebes la interrumpe sin gastarla.",
}
## Title of each effect (status icons and their tooltip).
const STATUS_TITLES: Dictionary[StringName, String] = {
	&"bleed": "Sangrado",
	&"slowed": "Ralentizado",
	&"rooted": "Enraizado",
	&"potion_regen": "Regeneración",
}
## Short description of each effect for the tooltip.
const STATUS_DESCRIPTIONS: Dictionary[StringName, String] = {
	&"bleed": "Pierdes vida cada segundo.",
	&"slowed": "Te mueves más despacio.",
	&"rooted": "No puedes moverte, saltar ni esquivar.",
	&"potion_regen": "Recuperas vida cada medio segundo.",
}
## Name of each weapon.
const WEAPON_TITLES: Dictionary[StringName, String] = {
	&"sword_shield": "Espada y escudo",
	&"bow": "Arco",
}
## Name of each equipment template.
const TEMPLATE_TITLES: Dictionary[StringName, String] = {
	&"squire": "Escudero",
	&"marksman": "Tirador",
}
## Who killed when the server gives no author (the environment) or they are not known.
const TEXT_ENVIRONMENT: String = "el entorno"
const TEXT_UNKNOWN_KILLER: String = "un enemigo"
const TEXT_UNKNOWN_ATTACK: String = "un ataque"
## Sentence for dying when the event with the author has not arrived.
const TEXT_FALLEN: String = "Has caído en combate."
## Special sources after "con" (with).
const TEXT_EXECUTE: String = "un remate"
const TEXT_BLEED_OUT: String = "el desangrado"
## Death screen sentences with the special sources.
const TEXT_EXECUTED_BY: String = "Te ha rematado %s."
const TEXT_BLED_OUT: String = "Te has desangrado."
const TEXT_BLED_OUT_BY: String = "Te has desangrado: te derribó %s."
## Knockdown notices (docs/habilidades.md, section 6.5).
const TEXT_DOWNED: String = "Derribado"
const TEXT_DOWNED_COUNTDOWN: String = "Te desangras en %d s"
const TEXT_BEING_REVIVED: String = "Te están levantando"
const TEXT_BEING_REVIVED_BY: String = "%s te está levantando"
const TEXT_BEING_EXECUTED: String = "¡Te rematan!"
const TEXT_REVIVE_PROMPT: String = "Mantén %s para levantar a %s"
const TEXT_REVIVING: String = "Levantando a %s"
const TEXT_ALLY: String = "un aliado"
## Action bar texts.
const TEXT_LIGHT: String = "Ataque ligero"
const TEXT_HEAVY: String = "Ataque fuerte (mantener)"
const TEXT_QUICK_SHOT: String = "Disparo rápido"
const TEXT_DRAWN_SHOT: String = "Disparo tensado (mantener)"
const TEXT_BLOCK: String = "Bloquear"
const TEXT_DODGE: String = "Esquivar"
const TEXT_SWAP: String = "Cambiar de arma"
const TEXT_SWAP_TO: String = "Cambiar a %s"
const TEXT_NO_SECOND_WEAPON: String = "Sin segunda arma"
const TEXT_CHARGES: String = "%d cargas"
const TEXT_COOLDOWN: String = "Reutilización: %s s"
const TEXT_EMPTY_SLOT: String = "Ranura vacía"
## Template selector.
const TEXT_TEMPLATE_TITLE: String = "Equipo para la próxima aparición"
const TEXT_TEMPLATE_CHARGES: String = "Pociones: %d de vida y %d de resistencia"
const TEXT_TEMPLATE_PENDING: String = "Se aplicará al reaparecer"


## Name (after "con", with) of the source [param source] ([CombatSource]) of a HIT, DEATH, KILL or HEAL: an
## attack, an ability, an effect's pulse, an execution or bleed-out. 0 (the environment) gives an empty
## string; an unknown source or one without text gives "un ataque" (an attack).
static func source_label(source: int) -> String:
	if source == CombatSource.NONE:
		return ""
	var id: int = CombatSource.id_of(source)
	match CombatSource.kind_of(source):
		CombatSource.Kind.ATTACK:
			var attack: AttackTicks = CombatCatalog.attack(id)
			return ATTACK_LABELS.get(attack.name, TEXT_UNKNOWN_ATTACK) if attack != null \
					else TEXT_UNKNOWN_ATTACK
		CombatSource.Kind.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(id)
			return ABILITY_LABELS.get(ability.name, TEXT_UNKNOWN_ATTACK) if ability != null \
					else TEXT_UNKNOWN_ATTACK
		CombatSource.Kind.STATUS:
			var status: StatusTicks = CombatCatalog.status(id)
			return STATUS_LABELS.get(status.name, TEXT_UNKNOWN_ATTACK) if status != null \
					else TEXT_UNKNOWN_ATTACK
	if source == CombatSource.EXECUTE:
		return TEXT_EXECUTE
	if source == CombatSource.BLEED_OUT:
		return TEXT_BLEED_OUT
	return TEXT_UNKNOWN_ATTACK


## Name of the attack with id [param attack_id] in the catalog (0 = none -> empty string; unknown
## or textless id -> "un ataque", an attack). Since an attack's source is its id, it also works for
## any source ([method source_label]).
static func attack_label(attack_id: int) -> String:
	return source_label(attack_id)


## Death screen sentence: "Te ha derrotado Ana con un golpe pesado." (Ana defeated you with a heavy blow),
## "Has muerto por el entorno." (you died to the environment), "Te ha derrotado un enemigo." (an enemy defeated
## you), "Te ha rematado Ana." (Ana executed you) or "Te has desangrado: te derribó Ana." (you bled out:
## Ana knocked you down). [param killer_name] is the name of whoever dealt the killing blow (empty
## if unknown), [param killer_id] their network id (0 = the environment) and [param source] the source of
## the DEATH ([CombatSource]).
static func death_text(killer_id: int, killer_name: String, source: int) -> String:
	var who: String = killer_name if not killer_name.is_empty() else TEXT_UNKNOWN_KILLER
	if source == CombatSource.BLEED_OUT:
		return TEXT_BLED_OUT if killer_id == 0 else TEXT_BLED_OUT_BY % who
	if killer_id == 0:
		return "Has muerto por %s." % TEXT_ENVIRONMENT
	if source == CombatSource.EXECUTE:
		return TEXT_EXECUTED_BY % who
	var with_what: String = source_label(source)
	if with_what.is_empty():
		return "Te ha derrotado %s." % who
	return "Te ha derrotado %s con %s." % [who, with_what]


## Title of ability [param ability_id] in the catalog ("Golpe de escudo", Shield bash); the resource name
## if it has no text and empty if it does not exist.
static func ability_title(ability_id: int) -> String:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	if ability == null:
		return ""
	return ABILITY_TITLES.get(ability.name, String(ability.name).capitalize())


## Short description of ability [param ability_id] (empty if it has none).
static func ability_description(ability_id: int) -> String:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	return ABILITY_DESCRIPTIONS.get(ability.name, "") if ability != null else ""


## Title of effect [param status_id] in the catalog ("Sangrado", Bleeding).
static func status_title(status_id: int) -> String:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null:
		return ""
	return STATUS_TITLES.get(status.name, String(status.name).capitalize())


## Short description of effect [param status_id] (empty if it has none).
static func status_description(status_id: int) -> String:
	var status: StatusTicks = CombatCatalog.status(status_id)
	return STATUS_DESCRIPTIONS.get(status.name, "") if status != null else ""


## Name of weapon [param weapon_id] in the catalog ("Arco", Bow).
static func weapon_title(weapon_id: int) -> String:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null:
		return ""
	return WEAPON_TITLES.get(weapon.name, String(weapon.name).capitalize())


## Name of template [param template_id] in the catalog ("Tirador", Marksman).
static func template_title(template_id: int) -> String:
	var template: EquipmentTemplate = CombatCatalog.template(template_id)
	if template == null:
		return ""
	return TEMPLATE_TITLES.get(template.id, String(template.id).capitalize())


## "Arco y Espada y escudo · Pociones: 2 de vida y 3 de resistencia" (Bow and Sword and shield · Potions: 2 health and
## 3 stamina): what template [param template_id] carries.
static func template_summary(template_id: int) -> String:
	var names: PackedStringArray = PackedStringArray()
	for weapon: int in CombatCatalog.template_weapons(template_id):
		if weapon != 0:
			names.append(weapon_title(weapon))
	var charges: int = CombatCatalog.template_charges(template_id)
	return "%s · %s" % [" + ".join(names), TEXT_TEMPLATE_CHARGES % [charges & 15, (charges >> 4) & 15]]
