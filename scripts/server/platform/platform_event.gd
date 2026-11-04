class_name PlatformEvent
extends RefCounted
## The result of a zone request to the platform's internal API (docs/plataforma.md §14.3), with the
## body already read. [ZonePlatform] stores them on arrival and delivers them in the tick's "poll" step with
## [method ZonePlatform.take_events]; each [member kind] has a single consumer:
## [codeblock]
## claim                                    auth_provider (plataforma.md P4)
## save                                     CharacterSaver (P5)
## heartbeat                                ZoneServer: revoked, mutes and maintenance
## id_block, progress_op, progress_ledger   ProgressService (progresion.md P5a and P5d)
## fortress                                 FortressPersistence (P6)
## ignore, report, sanction                 ChatRouter and moderation (P7b)
## instance_closed                          ServerMain: the shutdown of §6.1 (once)
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
## [member error_code] code of a body that is not JSON.
const BAD_JSON: String = "bad_json"
## Error codes that close the zone (§6.1).
const CLOSING_CODES: Array[String] = ["instance_lost", "instance_replaced", "instance_stopped"]

var kind: StringName = &""
## What the requester passed, as is.
var context: Variant = null
## false if there was no response: offline or deadline expired.
var transport_ok: bool = false
## HTTP status code (0 without a response).
var status: int = 0
## The body read with [JSON] (never [method JSON.parse_string]): null if it is empty, if the status is 204 or
## if it is not JSON (then [member error_code] is [constant BAD_JSON]).
var body: Variant = null
## The [code]error.code[/code] of an error body (§4.1), [constant BAD_JSON] or empty.
var error_code: String = ""


## true if the response is a 2xx.
func is_success() -> bool:
	return transport_ok and status >= 200 and status < 300


## The body as a dictionary (empty if it is not one).
func body_dict() -> Dictionary:
	return body if body is Dictionary else {}


## The [code]error[/code] object of an error body (§4.1), empty if it does not carry one.
func error_dict() -> Dictionary:
	return PlatformJson.dict_in(body_dict(), "error")


## Builds the event from a response: [param raw] are the body's bytes.
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
