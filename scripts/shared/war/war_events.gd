class_name WarEvents
extends RefCounted
## War notices of a fort (docs/fuerte.md, section 5): the ids that travel in the ENTITY_EVENT
## [code]WAR[/code] (data [code]u8 war_event, u8 realm[/code]) and their texts in Spanish.
## [br][br]
## [FortressState] returns these ids when advancing; the server sends them to the whole zone with
## the realm that corresponds to each one ([method FortressState.event_realm]) and the client shows
## them with [method text] at the draw tick. The caps (one attack notice per minute, one contest
## every 10 s) are applied by [FortressState].
## [br][br]
## Shared: depends on neither the client nor the server.

## Fort under attack (realm = the attacker): a hit on the gate or on a defender.
const UNDER_ATTACK: int = 1
## Captain down (realm = whoever killed it).
const CAPTAIN_DOWN: int = 2
## Capture started (realm = the capturer).
const CAPTURE_STARTED: int = 3
## Capture contested (realm = the capturer).
const CAPTURE_CONTESTED: int = 4
## Gate broken (realm = whoever broke it).
const GATE_BROKEN: int = 5
## Fort captured (realm = the new owner).
const FORT_CAPTURED: int = 6
## Fort reset to neutral (realm 0).
const FORT_RESET: int = 7

const FIRST: int = UNDER_ATTACK
const LAST: int = FORT_RESET

## Name of the fort used in texts if no other is given.
const DEFAULT_FORTRESS_NAME: String = "Fuerte"

## Id -> internal name (for logs and tests).
const _KEYS: Dictionary = {
	UNDER_ATTACK: &"under_attack",
	CAPTAIN_DOWN: &"captain_down",
	CAPTURE_STARTED: &"capture_started",
	CAPTURE_CONTESTED: &"capture_contested",
	GATE_BROKEN: &"gate_broken",
	FORT_CAPTURED: &"fort_captured",
	FORT_RESET: &"fort_reset",
}

## Id -> template in Spanish, with [code]{reino}[/code] and [code]{fuerte}[/code].
const _TEXTS: Dictionary = {
	UNDER_ATTACK: "¡{reino} ataca el {fuerte}!",
	CAPTAIN_DOWN: "¡El capitán del {fuerte} ha caído ante {reino}!",
	CAPTURE_STARTED: "{reino} empieza a capturar el {fuerte}.",
	CAPTURE_CONTESTED: "La captura del {fuerte} está disputada.",
	GATE_BROKEN: "¡{reino} ha derribado la puerta del {fuerte}!",
	FORT_CAPTURED: "¡{reino} ha capturado el {fuerte}!",
	FORT_RESET: "El {fuerte} ha vuelto a quedar sin dueño.",
}


## All notice ids, in order.
static func all_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in range(FIRST, LAST + 1):
		ids.append(id)
	return ids


## true if [param event_id] is a known notice (1 to 7).
static func is_valid(event_id: int) -> bool:
	return _KEYS.has(event_id)


## Internal name of the notice (for example [code]fort_captured[/code]); empty if it does not
## exist.
static func key_of(event_id: int) -> StringName:
	return _KEYS.get(event_id, &"")


## Spanish text of notice [param event_id] for realm [param realm] (network code; 0 = the Hollow)
## and fort [param fortress_name] ([member FortressDefinition.display_name]). Empty if the id does
## not exist.
static func text(event_id: int, realm: int, fortress_name: String = DEFAULT_FORTRESS_NAME) -> String:
	if not _TEXTS.has(event_id):
		return ""
	var template: String = _TEXTS[event_id]
	return template.format({"reino": realm_label(realm), "fuerte": fortress_name})


## Realm name for texts: "Vardheim", "Solmarch"..., or "los Huecos" (the Hollow) for the neutral
## side.
static func realm_label(realm: int) -> String:
	if realm == RealmCatalog.NEUTRAL_CODE:
		return "los Huecos"
	var label: String = RealmCatalog.display_name(RealmCatalog.id_of_code(realm))
	return label if not label.is_empty() else "un reino desconocido"
