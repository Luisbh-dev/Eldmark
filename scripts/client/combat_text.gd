class_name CombatText
extends RefCounted
## Textos en español del combate para la interfaz (pantalla de muerte, avisos): cómo se llama cada
## ataque del catálogo y la frase de «quién te derrotó y con qué».

## Nombre de cada ataque del catálogo ([member AttackDefinition.id]) tal como se lee en pantalla.
const ATTACK_LABELS: Dictionary[StringName, String] = {
	&"sword_light_1": "un tajo ligero",
	&"sword_light_2": "un tajo ligero",
	&"sword_light_3": "un tajo ligero final",
	&"sword_heavy": "un golpe pesado",
}
## Quién mató cuando el servidor no da un autor (el entorno) o no se le conoce.
const TEXT_ENVIRONMENT: String = "el entorno"
const TEXT_UNKNOWN_KILLER: String = "un enemigo"
const TEXT_UNKNOWN_ATTACK: String = "un ataque"
## Frase cuando se muere sin que haya llegado el evento con el autor.
const TEXT_FALLEN: String = "Has caído en combate."


## Nombre del ataque con id [param attack_id] del catálogo (0 = ninguno -> cadena vacía; id
## desconocido o sin texto -> «un ataque»).
static func attack_label(attack_id: int) -> String:
	if attack_id == 0:
		return ""
	var attack: AttackTicks = CombatCatalog.attack(attack_id)
	if attack == null:
		return TEXT_UNKNOWN_ATTACK
	return ATTACK_LABELS.get(attack.name, TEXT_UNKNOWN_ATTACK)


## Frase de la pantalla de muerte: «Te ha derrotado Ana con un golpe pesado.»,
## «Has muerto por el entorno.» o «Te ha derrotado un enemigo.». [param killer_name] es el nombre
## de quien dio el golpe de gracia (vacío si no se le conoce) y [param killer_id] su id de red (0 =
## el entorno).
static func death_text(killer_id: int, killer_name: String, attack_id: int) -> String:
	if killer_id == 0:
		return "Has muerto por %s." % TEXT_ENVIRONMENT
	var who: String = killer_name if not killer_name.is_empty() else TEXT_UNKNOWN_KILLER
	var with_what: String = attack_label(attack_id)
	if with_what.is_empty():
		return "Te ha derrotado %s." % who
	return "Te ha derrotado %s con %s." % [who, with_what]
