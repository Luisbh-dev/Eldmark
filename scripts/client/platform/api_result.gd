class_name ApiResult
extends RefCounted
## La respuesta de una llamada a la API pública de la plataforma (docs/plataforma.md §4.1 y §14.4), la que devuelve
## [method PlatformApi.call_api].
## [br][br]
## [member ok] es true con un 2xx. Con un error, [member data] es el objeto [code]error[/code] del cuerpo entero
## ([code]{code, message, retry_after_s, fields, …}[/code], con lo propio de cada código: [code]until[/code] y
## [code]reason[/code] de una sanción, [code]realm[/code] y [code]unlock_at[/code] de [code]realm_locked[/code]…) y
## [member code], [member message] y [member retry_after_s] salen de él. Sin respuesta (sin conexión, plazo
## vencido, fallo de TLS) [member status] es 0 y [member code] es [constant CODE_NETWORK]. El texto para el jugador
## lo da [method PlatformErrors.text_for]. Solo cliente.

## Código de una llamada sin respuesta del servidor (sin conexión, plazo vencido, TLS).
const CODE_NETWORK: String = "network"
## Código de una respuesta que no se entiende (un error sin cuerpo JSON de error).
const CODE_BAD_RESPONSE: String = "bad_response"
## Código de una URL de plataforma que no se admite (http:// fuera de esta máquina…): la llamada no sale.
const CODE_BAD_URL: String = "bad_url"
## Código de una llamada con sesión sin sesión iniciada: no sale.
const CODE_NO_SESSION: String = "unauthorized"

var ok: bool = false
## Código HTTP (0 sin respuesta).
var status: int = 0
## El cuerpo JSON (un objeto) de un 2xx, o el objeto [code]error[/code] de un error. Vacío con un 204 o un cuerpo
## que no es un objeto JSON (entonces está en [member text]).
var data: Dictionary = {}
## Código de error de la plataforma ([code]name_taken[/code]…); vacío si [member ok].
var code: String = ""
## Mensaje de la plataforma (o el del cliente si no hay respuesta).
var message: String = ""
## Segundos que pide esperar un 429 o un 503 (del cuerpo o de [code]Retry-After[/code]).
var retry_after_s: int = 0
## El cuerpo como texto (UTF-8 válido): el Markdown de [code]/v1/legal/{kind}[/code], el JSON de la exportación…
var text: String = ""
## Cabeceras de la respuesta, tal cual.
var headers: PackedStringArray = PackedStringArray()


## Una respuesta correcta con [param body] (pruebas y [member PlatformApi.request_hook]).
static func success(body: Dictionary = {}, http_status: int = 200) -> ApiResult:
	var result := ApiResult.new()
	result.ok = true
	result.status = http_status
	result.data = body
	return result


## Una respuesta de error con el cuerpo de §4.1 (pruebas y [member PlatformApi.request_hook]). [param extra] añade
## campos al objeto [code]error[/code] ([code]until[/code], [code]fields[/code]…).
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


## Una llamada que no recibió respuesta (o que no llegó a salir) con el código [param error_code].
static func no_response(error_code: String = CODE_NETWORK, error_message: String = "") -> ApiResult:
	var result := ApiResult.new()
	result.ok = false
	result.status = 0
	result.code = error_code
	result.message = error_message
	result.data = {"code": error_code, "message": error_message}
	return result


## [code]fields[/code] del error de validación ({campo: motivo}); vacío si no hay.
func get_fields() -> Dictionary:
	var fields: Variant = data.get("fields", {})
	return fields if fields is Dictionary else {}


## Un campo de texto de [member data] (vacío si falta o no es texto).
func text_of(key: String) -> String:
	var value: Variant = data.get(key)
	return value if value is String else ""


## Un campo entero de [member data] ([param fallback] si falta o no es un número entero). Los números de JSON
## llegan como float.
func int_of(key: String, fallback: int = 0) -> int:
	var value: Variant = data.get(key)
	if value is int:
		return value
	if value is float and is_finite(value) and value == floorf(value):
		return int(value)
	return fallback


## La cabecera [param header_name] (sin distinguir mayúsculas), o vacío.
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
