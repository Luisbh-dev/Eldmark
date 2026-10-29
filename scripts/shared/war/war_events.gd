class_name WarEvents
extends RefCounted
## Avisos de guerra de una fortaleza (docs/fuerte.md, sección 5): los ids que viajan en el
## ENTITY_EVENT [code]WAR[/code] (datos [code]u8 war_event, u8 realm[/code]) y sus textos en español.
## [br][br]
## [FortressState] devuelve estos ids al avanzar; el servidor los manda a toda la zona con el reino
## que corresponde a cada uno ([method FortressState.event_realm]) y el cliente los muestra con
## [method text] en el tick de dibujo. Los topes (un aviso de ataque por minuto, una disputa cada
## 10 s) los aplica [FortressState].
## [br][br]
## Compartido: no depende del cliente ni del servidor.

## Fuerte atacado (reino = el atacante): un golpe a la puerta o a un defensor.
const UNDER_ATTACK: int = 1
## Capitán caído (reino = quien lo mató).
const CAPTAIN_DOWN: int = 2
## Captura iniciada (reino = el captor).
const CAPTURE_STARTED: int = 3
## Captura disputada (reino = el captor).
const CAPTURE_CONTESTED: int = 4
## Puerta rota (reino = quien la rompió).
const GATE_BROKEN: int = 5
## Fuerte capturado (reino = el nuevo dueño).
const FORT_CAPTURED: int = 6
## Fuerte reiniciado a neutral (reino 0).
const FORT_RESET: int = 7

const FIRST: int = UNDER_ATTACK
const LAST: int = FORT_RESET

## Nombre del fuerte que se usa en los textos si no se indica otro.
const DEFAULT_FORTRESS_NAME: String = "Fuerte"

## Id -> nombre interno (para registros y pruebas).
const _KEYS: Dictionary = {
	UNDER_ATTACK: &"under_attack",
	CAPTAIN_DOWN: &"captain_down",
	CAPTURE_STARTED: &"capture_started",
	CAPTURE_CONTESTED: &"capture_contested",
	GATE_BROKEN: &"gate_broken",
	FORT_CAPTURED: &"fort_captured",
	FORT_RESET: &"fort_reset",
}

## Id -> plantilla en español, con [code]{reino}[/code] y [code]{fuerte}[/code].
const _TEXTS: Dictionary = {
	UNDER_ATTACK: "¡{reino} ataca el {fuerte}!",
	CAPTAIN_DOWN: "¡El capitán del {fuerte} ha caído ante {reino}!",
	CAPTURE_STARTED: "{reino} empieza a capturar el {fuerte}.",
	CAPTURE_CONTESTED: "La captura del {fuerte} está disputada.",
	GATE_BROKEN: "¡{reino} ha derribado la puerta del {fuerte}!",
	FORT_CAPTURED: "¡{reino} ha capturado el {fuerte}!",
	FORT_RESET: "El {fuerte} ha vuelto a quedar sin dueño.",
}


## Todos los ids de aviso, en orden.
static func all_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in range(FIRST, LAST + 1):
		ids.append(id)
	return ids


## true si [param event_id] es un aviso conocido (1 a 7).
static func is_valid(event_id: int) -> bool:
	return _KEYS.has(event_id)


## Nombre interno del aviso (por ejemplo [code]fort_captured[/code]); vacío si no existe.
static func key_of(event_id: int) -> StringName:
	return _KEYS.get(event_id, &"")


## Texto en español del aviso [param event_id] para el reino [param realm] (código de red; 0 = los
## Huecos) y la fortaleza [param fortress_name] ([member FortressDefinition.display_name]). Vacío
## si el id no existe.
static func text(event_id: int, realm: int, fortress_name: String = DEFAULT_FORTRESS_NAME) -> String:
	if not _TEXTS.has(event_id):
		return ""
	var template: String = _TEXTS[event_id]
	return template.format({"reino": realm_label(realm), "fuerte": fortress_name})


## Nombre del reino para los textos: «Vardheim», «Solmarch»..., o «los Huecos» para el bando neutral.
static func realm_label(realm: int) -> String:
	if realm == RealmCatalog.NEUTRAL_CODE:
		return "los Huecos"
	var label: String = RealmCatalog.display_name(RealmCatalog.id_of_code(realm))
	return label if not label.is_empty() else "un reino desconocido"
