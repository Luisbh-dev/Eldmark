class_name CombatText
extends RefCounted
## Textos en español del combate para la interfaz (pantalla de muerte, registro de bajas, barra de
## acciones, iconos de estados, avisos de derribado, selector de plantillas): cómo se llama cada
## ataque, habilidad, efecto, arma y plantilla del catálogo y la frase de «quién te derrotó y con qué».
## [br][br]
## Desde el protocolo 6 los eventos traen una [b]fuente[/b] ([CombatSource]: ataque, habilidad, efecto,
## remate o desangrado) en lugar de un id de ataque; [method source_label] la nombra. Los ataques
## conservan su número (su fuente es su id), así que [method attack_label] sigue valiendo para ellos.
## [br][br]
## Las tablas van por el [b]nombre[/b] del recurso ([code]id[/code] de su [code].tres[/code]): los ids
## numéricos del catálogo no son fijos (docs/habilidades.md, sección 2.2).

## Nombre de cada ataque del catálogo ([member AttackDefinition.id]) tal como se lee tras «con».
const ATTACK_LABELS: Dictionary[StringName, String] = {
	&"sword_light_1": "un tajo ligero",
	&"sword_light_2": "un tajo ligero",
	&"sword_light_3": "un tajo ligero final",
	&"sword_heavy": "un golpe pesado",
	&"bow_quick": "un disparo rápido",
	&"bow_drawn": "un disparo tensado",
}
## Nombre de cada habilidad (y poción) tal como se lee tras «con».
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
## Nombre de cada efecto tal como se lee tras «con» (el daño de sus pulsos).
const STATUS_LABELS: Dictionary[StringName, String] = {
	&"bleed": "un sangrado",
	&"slowed": "una ralentización",
	&"rooted": "un enraizamiento",
	&"potion_regen": "una curación",
}
## Título de cada habilidad (barra de acciones y su tooltip).
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
## Descripción corta de cada habilidad para el tooltip.
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
## Título de cada efecto (iconos de estados y su tooltip).
const STATUS_TITLES: Dictionary[StringName, String] = {
	&"bleed": "Sangrado",
	&"slowed": "Ralentizado",
	&"rooted": "Enraizado",
	&"potion_regen": "Regeneración",
}
## Descripción corta de cada efecto para el tooltip.
const STATUS_DESCRIPTIONS: Dictionary[StringName, String] = {
	&"bleed": "Pierdes vida cada segundo.",
	&"slowed": "Te mueves más despacio.",
	&"rooted": "No puedes moverte, saltar ni esquivar.",
	&"potion_regen": "Recuperas vida cada medio segundo.",
}
## Nombre de cada arma.
const WEAPON_TITLES: Dictionary[StringName, String] = {
	&"sword_shield": "Espada y escudo",
	&"bow": "Arco",
}
## Nombre de cada plantilla de equipo.
const TEMPLATE_TITLES: Dictionary[StringName, String] = {
	&"squire": "Escudero",
	&"marksman": "Tirador",
}
## Quién mató cuando el servidor no da un autor (el entorno) o no se le conoce.
const TEXT_ENVIRONMENT: String = "el entorno"
const TEXT_UNKNOWN_KILLER: String = "un enemigo"
const TEXT_UNKNOWN_ATTACK: String = "un ataque"
## Frase cuando se muere sin que haya llegado el evento con el autor.
const TEXT_FALLEN: String = "Has caído en combate."
## Fuentes especiales tras «con».
const TEXT_EXECUTE: String = "un remate"
const TEXT_BLEED_OUT: String = "el desangrado"
## Frases de la pantalla de muerte con las fuentes especiales.
const TEXT_EXECUTED_BY: String = "Te ha rematado %s."
const TEXT_BLED_OUT: String = "Te has desangrado."
const TEXT_BLED_OUT_BY: String = "Te has desangrado: te derribó %s."
## Avisos de derribado (docs/habilidades.md, sección 6.5).
const TEXT_DOWNED: String = "Derribado"
const TEXT_DOWNED_COUNTDOWN: String = "Te desangras en %d s"
const TEXT_BEING_REVIVED: String = "Te están levantando"
const TEXT_BEING_REVIVED_BY: String = "%s te está levantando"
const TEXT_BEING_EXECUTED: String = "¡Te rematan!"
const TEXT_REVIVE_PROMPT: String = "Mantén %s para levantar a %s"
const TEXT_REVIVING: String = "Levantando a %s"
const TEXT_ALLY: String = "un aliado"
## Textos de la barra de acciones.
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
## Selector de plantillas.
const TEXT_TEMPLATE_TITLE: String = "Equipo para la próxima aparición"
const TEXT_TEMPLATE_CHARGES: String = "Pociones: %d de vida y %d de resistencia"
const TEXT_TEMPLATE_PENDING: String = "Se aplicará al reaparecer"


## Nombre (tras «con») de la fuente [param source] ([CombatSource]) de un HIT, DEATH, KILL o HEAL: un
## ataque, una habilidad, el pulso de un efecto, un remate o el desangrado. 0 (el entorno) da una cadena
## vacía; una fuente desconocida o sin texto, «un ataque».
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


## Nombre del ataque con id [param attack_id] del catálogo (0 = ninguno -> cadena vacía; id
## desconocido o sin texto -> «un ataque»). Como la fuente de un ataque es su id, vale también para
## cualquier fuente ([method source_label]).
static func attack_label(attack_id: int) -> String:
	return source_label(attack_id)


## Frase de la pantalla de muerte: «Te ha derrotado Ana con un golpe pesado.»,
## «Has muerto por el entorno.», «Te ha derrotado un enemigo.», «Te ha rematado Ana.» o «Te has
## desangrado: te derribó Ana.». [param killer_name] es el nombre de quien dio el golpe de gracia (vacío
## si no se le conoce), [param killer_id] su id de red (0 = el entorno) y [param source] la fuente del
## DEATH ([CombatSource]).
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


## Título de la habilidad [param ability_id] del catálogo («Golpe de escudo»); el nombre del recurso
## si no tiene texto y vacío si no existe.
static func ability_title(ability_id: int) -> String:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	if ability == null:
		return ""
	return ABILITY_TITLES.get(ability.name, String(ability.name).capitalize())


## Descripción corta de la habilidad [param ability_id] (vacía si no tiene).
static func ability_description(ability_id: int) -> String:
	var ability: AbilityTicks = CombatCatalog.ability(ability_id)
	return ABILITY_DESCRIPTIONS.get(ability.name, "") if ability != null else ""


## Título del efecto [param status_id] del catálogo («Sangrado»).
static func status_title(status_id: int) -> String:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null:
		return ""
	return STATUS_TITLES.get(status.name, String(status.name).capitalize())


## Descripción corta del efecto [param status_id] (vacía si no tiene).
static func status_description(status_id: int) -> String:
	var status: StatusTicks = CombatCatalog.status(status_id)
	return STATUS_DESCRIPTIONS.get(status.name, "") if status != null else ""


## Nombre del arma [param weapon_id] del catálogo («Arco»).
static func weapon_title(weapon_id: int) -> String:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null:
		return ""
	return WEAPON_TITLES.get(weapon.name, String(weapon.name).capitalize())


## Nombre de la plantilla [param template_id] del catálogo («Tirador»).
static func template_title(template_id: int) -> String:
	var template: EquipmentTemplate = CombatCatalog.template(template_id)
	if template == null:
		return ""
	return TEMPLATE_TITLES.get(template.id, String(template.id).capitalize())


## «Arco y Espada y escudo · Pociones: 2 de vida y 3 de resistencia»: lo que lleva la plantilla
## [param template_id].
static func template_summary(template_id: int) -> String:
	var names: PackedStringArray = PackedStringArray()
	for weapon: int in CombatCatalog.template_weapons(template_id):
		if weapon != 0:
			names.append(weapon_title(weapon))
	var charges: int = CombatCatalog.template_charges(template_id)
	return "%s · %s" % [" + ".join(names), TEXT_TEMPLATE_CHARGES % [charges & 15, (charges >> 4) & 15]]
