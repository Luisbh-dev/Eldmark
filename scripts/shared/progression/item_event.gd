class_name ItemEvent
extends RefCounted
## Un evento de objeto (docs/progresion.md §3.3, §5.2 y §9.3, I4): lo único que cambia la cantidad total de
## una definición. Lo dan las fuentes, los sumideros, la reversión y la migración (§5.3); mover, dividir,
## juntar, intercambiar y equipar no dan ninguno. Pertenece a una operación ([code]EconomyOp[/code], del
## servidor), que lo lleva en su [code]items[/code].
## [br][br]
## [b]JSON[/b] ([method to_dictionary], §9.3): [code]{"uid": "1027", "def_id": "potion_health",
## "count_delta": -1, "reason": 65}[/code], con [code]uid[/code] null en un evento agregado (CAMP_REFILL,
## CONSUME). Compartido: sin reloj ni azar.

## Claves de [method to_dictionary], en orden alfabético.
const DICTIONARY_KEYS: Array[String] = ["count_delta", "def_id", "reason", "uid"]
## Mayor [member count_delta] en valor absoluto (la columna es [code]int[/code]).
const MAX_COUNT_DELTA: int = 0x7FFFFFFF

## La instancia de la que es (kit, GM, DESTROY del jugador); 0 = agregado (null en JSON).
var uid: int = 0
var def_id: StringName = &""
## Unidades que entran (> 0) o salen (< 0); nunca 0.
var count_delta: int = 0
## Motivo ([EconomyReason]); su signo cuadra con [member count_delta].
var reason: int = 0


## Un evento con esos valores.
static func create(event_uid: int, event_def_id: StringName, delta: int, event_reason: int) -> ItemEvent:
	var event := ItemEvent.new()
	event.uid = event_uid
	event.def_id = event_def_id
	event.count_delta = delta
	event.reason = event_reason
	return event


## La entrada de [code]items[/code] de una operación (§9.3): [code]uid[/code] como cadena decimal o null.
func to_dictionary() -> Dictionary:
	return {
		"uid": null if uid == 0 else ProgressJson.id_text(uid),
		"def_id": String(def_id),
		"count_delta": count_delta,
		"reason": reason,
	}


## Lee una entrada de [method to_dictionary]; null si no cuadra: una clave que falta o que no conoce, un
## [code]uid[/code] que no es null ni un id de 1 a 2^53 − 1 en cadena, un [code]def_id[/code] sin el formato
## de [constant ItemDefinition.ID_PATTERN], un [code]count_delta[/code] de 0 o fuera de rango, o un motivo
## cuyo signo no cuadra ([method EconomyReason.sign_matches]). No mira si la definición existe: un evento
## antiguo puede nombrar una que ya no está.
static func from_dictionary(data: Dictionary) -> ItemEvent:
	if data.size() != DICTIONARY_KEYS.size():
		return null
	for key: String in DICTIONARY_KEYS:
		if not data.has(key):
			return null
	var event_uid: int = 0
	if typeof(data["uid"]) != TYPE_NIL:
		if not ProgressJson.is_id(data["uid"], 1, ItemInstance.MAX_UID):
			return null
		event_uid = ProgressJson.id_value(data["uid"])
	var def_value: Variant = data["def_id"]
	if typeof(def_value) != TYPE_STRING and typeof(def_value) != TYPE_STRING_NAME:
		return null
	var id_regex := RegEx.new()
	id_regex.compile(ItemDefinition.ID_PATTERN)
	if id_regex.search(String(def_value)) == null:
		return null
	if not ProgressJson.is_int(data["count_delta"], -MAX_COUNT_DELTA, MAX_COUNT_DELTA) \
			or not ProgressJson.is_int(data["reason"], 1, 0xFF):
		return null
	var delta: int = int(data["count_delta"])
	var event_reason: int = int(data["reason"])
	if not EconomyReason.sign_matches(event_reason, delta):
		return null
	return create(event_uid, StringName(def_value), delta, event_reason)


## true si [param other] tiene los mismos valores.
func equals(other: ItemEvent) -> bool:
	return other != null and uid == other.uid and def_id == other.def_id \
			and count_delta == other.count_delta and reason == other.reason


func _to_string() -> String:
	return "ItemEvent(uid=%d, %s, %+d, motivo %d)" % [uid, def_id, count_delta, reason]
