class_name PlatformEvent
extends RefCounted
## El resultado de una petición de la zona a la API interna de la plataforma (docs/plataforma.md §14.3), con el
## cuerpo ya leído. [ZonePlatform] los guarda al llegar y los entrega en el paso «poll» del tick con
## [method ZonePlatform.take_events]; cada [member kind] tiene un solo consumidor:
## [codeblock]
## claim                                    auth_provider (plataforma.md P4)
## save                                     CharacterSaver (P5)
## heartbeat                                ZoneServer: revoked, mutes y maintenance
## id_block, progress_op, progress_ledger   ProgressService (progresion.md P5a y P5d)
## fortress                                 FortressPersistence (P6)
## ignore, report, sanction                 ChatRouter y la moderación (P7b)
## instance_closed                          ServerMain: el cierre de §6.1 (una vez)
## [/codeblock]

const KIND_CLAIM: StringName = &"claim"
const KIND_SAVE: StringName = &"save"
const KIND_HEARTBEAT: StringName = &"heartbeat"
const KIND_ID_BLOCK: StringName = &"id_block"
const KIND_PROGRESS_OP: StringName = &"progress_op"
const KIND_PROGRESS_LEDGER: StringName = &"progress_ledger"
const KIND_FORTRESS: StringName = &"fortress"
const KIND_IGNORE: StringName = &"ignore"
const KIND_REPORT: StringName = &"report"
const KIND_SANCTION: StringName = &"sanction"
const KIND_INSTANCE_CLOSED: StringName = &"instance_closed"
## Código de [member error_code] de un cuerpo que no es JSON.
const BAD_JSON: String = "bad_json"
## Códigos de error que cierran la zona (§6.1).
const CLOSING_CODES: Array[String] = ["instance_lost", "instance_replaced", "instance_stopped"]

var kind: StringName = &""
## Lo que pasó quien hizo la petición, tal cual.
var context: Variant = null
## false si no hubo respuesta: sin conexión o plazo vencido.
var transport_ok: bool = false
## Código HTTP (0 sin respuesta).
var status: int = 0
## El cuerpo leído con [JSON] (nunca [method JSON.parse_string]): null si está vacío, si el estado es 204 o
## si no es JSON (entonces [member error_code] es [constant BAD_JSON]).
var body: Variant = null
## El [code]error.code[/code] del cuerpo de un error (§4.1), [constant BAD_JSON] o vacío.
var error_code: String = ""


## true si la respuesta es un 2xx.
func is_success() -> bool:
	return transport_ok and status >= 200 and status < 300


## El cuerpo como diccionario (vacío si no lo es).
func body_dict() -> Dictionary:
	return body if body is Dictionary else {}


## El objeto [code]error[/code] de un cuerpo de error (§4.1), vacío si no lo trae.
func error_dict() -> Dictionary:
	return PlatformJson.dict_in(body_dict(), "error")


## Arma el evento de una respuesta: [param raw] son los bytes del cuerpo.
static func from_response(event_kind: StringName, event_context: Variant, ok: bool, http_status: int,
		raw: PackedByteArray) -> PlatformEvent:
	var event := PlatformEvent.new()
	event.kind = event_kind
	event.context = event_context
	event.transport_ok = ok
	event.status = http_status if ok else 0
	if not ok or http_status == 204:
		return event
	var parsed: Dictionary = PlatformJson.parse(raw)
	if not parsed["ok"]:
		event.error_code = BAD_JSON
		return event
	event.body = parsed["data"]
	if http_status >= 400:
		event.error_code = PlatformJson.text_in(event.error_dict(), "code")
	return event
