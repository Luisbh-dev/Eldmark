class_name ApiResult
extends RefCounted
## The response of a call to the platform's public API (docs/platform.md §4.1 and §14.4), the one returned by
## [method PlatformApi.call_api].
## [br][br]
## [member ok] is true on a 2xx. On an error, [member data] is the [code]error[/code] object of the whole body
## ([code]{code, message, retry_after_s, fields, …}[/code], with what is specific to each code: [code]until[/code] and
## [code]reason[/code] of a sanction, [code]realm[/code] and [code]unlock_at[/code] of [code]realm_locked[/code]…) and
## [member code], [member message] and [member retry_after_s] come from it. With no response (offline, timeout
## expired, TLS failure) [member status] is 0 and [member code] is [constant CODE_NETWORK]. The text for the player
## is given by [method PlatformErrors.text_for]. Client only.

## Code of a call with no response from the server (offline, timeout expired, TLS).
const CODE_NETWORK: String = "network"
## Code of a response that is not understood (an error without a JSON error body).
const CODE_BAD_RESPONSE: String = "bad_response"
## Code of a platform URL that is not admitted (http:// outside this machine…): the call does not go out.
const CODE_BAD_URL: String = "bad_url"
## Code of a call that needs a session made without being logged in: it does not go out.
const CODE_NO_SESSION: String = "unauthorized"

var ok: bool = false
## HTTP code (0 without a response).
var status: int = 0
## The JSON body (an object) of a 2xx, or the [code]error[/code] object of an error. Empty with a 204 or a body
## that is not a JSON object (then it is in [member text]).
var data: Dictionary = {}
## Platform error code ([code]name_taken[/code]…); empty if [member ok].
var code: String = ""
## Message from the platform (or the client's if there is no response).
var message: String = ""
## Seconds a 429 or a 503 asks to wait (from the body or from [code]Retry-After[/code]).
var retry_after_s: int = 0
## The body as text (valid UTF-8): the Markdown of [code]/v1/legal/{kind}[/code], the JSON of the export…
var text: String = ""
## Response headers, as is.
var headers: PackedStringArray = PackedStringArray()


## A successful response with [param body] (tests and [member PlatformApi.request_hook]).
static func success(body: Dictionary = {}, http_status: int = 200) -> ApiResult:
	var result := ApiResult.new()
	result.ok = true
	result.status = http_status
	result.data = body
	return result


## An error response with the body from §4.1 (tests and [member PlatformApi.request_hook]). [param extra] adds
## fields to the [code]error[/code] object ([code]until[/code], [code]fields[/code]…).
static func failure(http_status: int, error_code: String, error_message: String = "", extra: Dictionary = {},
		retry_after: int = 0) -> ApiResult:
	var result := ApiResult.new()
	result.ok = false
	result.status = http_status
	result.code = error_code
	result.message = error_message
	result.retry_after_s = retry_after
	var error: Dictionary = extra.duplicate(true)
	error["code"] = error_code
	error["message"] = error_message
	error["retry_after_s"] = retry_after
	result.data = error
	return result


## A call that received no response (or never got to go out) with code [param error_code].
static func no_response(error_code: String = CODE_NETWORK, error_message: String = "") -> ApiResult:
	var result := ApiResult.new()
	result.ok = false
	result.status = 0
	result.code = error_code
	result.message = error_message
	result.data = {"code": error_code, "message": error_message}
	return result


## [code]fields[/code] of the validation error ({field: reason}); empty if there is none.
func get_fields() -> Dictionary:
	var fields: Variant = data.get("fields", {})
	return fields if fields is Dictionary else {}


## A text field of [member data] (empty if missing or not text).
func text_of(key: String) -> String:
	var value: Variant = data.get(key)
	return value if value is String else ""


## An integer field of [member data] ([param fallback] if missing or not an integer). JSON numbers
## arrive as float.
func int_of(key: String, fallback: int = 0) -> int:
	var value: Variant = data.get(key)
	if value is int:
		return value
	if value is float and is_finite(value) and value == floorf(value):
		return int(value)
	return fallback


## The header [param header_name] (case-insensitive), or empty.
func header(header_name: String) -> String:
	var wanted: String = header_name.to_lower() + ":"
	for line: String in headers:
		if line.to_lower().begins_with(wanted):
			return line.substr(wanted.length()).strip_edges()
	return ""


func _to_string() -> String:
	if ok:
		return "ApiResult(%d)" % status
	return "ApiResult(%d %s)" % [status, code]
