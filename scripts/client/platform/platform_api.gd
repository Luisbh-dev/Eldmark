class_name PlatformApi
extends Node
## Cliente de la API pública de la plataforma (docs/plataforma.md §4 y §14.4): HTTPS y JSON con las cabeceras de
## §4.1 ([code]Authorization[/code], [code]X-Eldmark-Protocol[/code] y [code]X-Eldmark-Build[/code]).
## [br][br]
## [method call_api] es una corrutina que devuelve un [ApiResult]:
## [codeblock]
## var result: ApiResult = await api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", {…}, false)
## [/codeblock]
## [b]Sesión.[/b] Las llamadas con sesión ([param auth]) llevan el token de acceso de [member session]. Si caduca en
## menos de un minuto se refresca antes; si la plataforma responde 401 [code]unauthorized[/code] se refresca una vez y
## se repite la llamada. [b]Un solo refresco en vuelo[/b] (§4.2): las llamadas que lo necesitan a la vez esperan al
## mismo (señal [signal refreshed]), así la plataforma nunca ve dos refrescos con el mismo token, que tomaría por
## reutilización y cerraría la sesión. Si el refresco da 401, la sesión se olvida y sale [signal session_lost]: quien
## muestra la interfaz vuelve al título.
## [br][br]
## [b]Transporte.[/b] Un [HTTPRequest] por llamada (en el árbol: este nodo tiene que estar en él), con
## [member timeout_s] de plazo. Solo [code]https://[/code] o, hacia esta máquina, [code]http://[/code]
## ([method ClientConfig.platform_url_error]); con el ajuste [constant CA_CERT_SETTING] (ruta a un PEM) se ancla ese
## certificado (staging con certificado propio, §10.1). Un cuerpo que no es UTF-8 o JSON nunca registra errores del
## motor. Los ids van siempre como cadena (§4.1): quien arma un cuerpo los pone con [code]str()[/code].
## [br][br]
## [b]Pruebas.[/b] [member request_hook] sustituye al transporte: recibe [code](method, path, body)[/code] y devuelve un
## [ApiResult] (puede ser una corrutina, para simular una respuesta lenta). Todo lo demás (refresco, reintento tras
## el 401, [signal session_lost]) corre igual. Solo cliente.

## El refresco es imposible (la sesión ya no vale): la interfaz vuelve al título. [param code] es el del error.
signal session_lost(code: String)
## Ha terminado un refresco ([param ok]: si salió bien). Interna: la esperan las llamadas que llegan mientras vuela.
signal refreshed(ok: bool)

## Plazo de cada petición (s).
const TIMEOUT_S: float = 15.0
## Tamaño máximo de una respuesta (la exportación de datos es la más grande).
const MAX_RESPONSE_BYTES: int = 8 * 1024 * 1024
const REFRESH_PATH: String = "/v1/sessions/refresh"
## Ajuste de proyecto con la ruta de un certificado PEM que anclar (vacío = los raíz de Godot).
const CA_CERT_SETTING: String = "eldmark/platform/ca_cert"
const PROTOCOL_HEADER: String = "X-Eldmark-Protocol"
const BUILD_HEADER: String = "X-Eldmark-Build"

## URL base de la API pública ([code]https://cuentas.eldmark.example[/code], sin barra final).
var base_url: String = ""
## Pruebas: [code](method: int, path: String, body: Variant) -> ApiResult[/code] en lugar de la red.
var request_hook: Callable = Callable()
## La sesión de la cuenta (la pone [AccountFlow] al iniciar sesión).
var session: AccountSession = AccountSession.new()
## Plazo de cada petición (s).
var timeout_s: float = TIMEOUT_S
## Pruebas: [code]() -> int[/code] con la hora en ms en lugar de [method Time.get_ticks_msec].
var clock: Callable = Callable()

var _refreshing: bool = false
var _last_refresh: ApiResult = null
var _refresh_count: int = 0
var _calls: int = 0


func _init() -> void:
	name = "PlatformApi"


## Llama a [param path] (con el prefijo [code]/v1[/code]) con [param method] y el cuerpo [param body] (un diccionario
## que se manda como JSON; null = sin cuerpo). Con [param auth], con la sesión (y su refresco). Corrutina.
func call_api(method: HTTPClient.Method, path: String, body: Variant = null, auth: bool = true) -> ApiResult:
	_calls += 1
	if auth:
		if not session.is_active():
			return ApiResult.failure(401, ApiResult.CODE_NO_SESSION, "Tu sesión ha caducado")
		if session.needs_refresh(now_msec()):
			var early: ApiResult = await _refresh()
			if not early.ok:
				return early
	var sent_token: String = session.access_token if auth else ""
	var result: ApiResult = await _send(method, path, body, auth)
	if auth and result.status == 401 and result.code == "unauthorized":
		# Si otra llamada ya refrescó mientras esta volaba, basta con repetir con el token nuevo.
		if session.access_token == sent_token:
			var refresh: ApiResult = await _refresh()
			if not refresh.ok:
				return refresh if refresh.status != 401 else result
		if not session.is_active():
			return result
		result = await _send(method, path, body, auth)
	return result


## Refrescos hechos desde que existe este nodo (pruebas: dos llamadas que caducan a la vez hacen uno).
func get_refresh_count() -> int:
	return _refresh_count


## Llamadas a [method call_api] desde que existe este nodo.
func get_call_count() -> int:
	return _calls


## true mientras vuela un refresco.
func is_refreshing() -> bool:
	return _refreshing


## La hora (ms) con la que se miran los plazos de la sesión.
func now_msec() -> int:
	if clock.is_valid():
		return int(clock.call())
	return Time.get_ticks_msec()


## Identificador de esta versión del cliente para [constant BUILD_HEADER]: [code]eldmark-<versión>-p<protocolo>[/code]
## (el mismo formato que el registro de las zonas).
static func build_id() -> String:
	var version: String = str(ProjectSettings.get_setting("application/config/version", "0"))
	return ("eldmark-%s-p%d" % [version, NetProtocol.PROTOCOL_VERSION]).replace(" ", "_").left(64)


## Las cabeceras de una petición con el token [param access_token] (vacío = sin sesión) y con o sin cuerpo.
static func request_headers(access_token: String, has_body: bool) -> PackedStringArray:
	var headers := PackedStringArray([
		"Accept: application/json",
		"%s: %d" % [PROTOCOL_HEADER, NetProtocol.PROTOCOL_VERSION],
		"%s: %s" % [BUILD_HEADER, build_id()],
	])
	if not access_token.is_empty():
		headers.append("Authorization: Bearer %s" % access_token)
	if has_body:
		headers.append("Content-Type: application/json")
	return headers


## Convierte lo que da [signal HTTPRequest.request_completed] en un [ApiResult] (sin registrar errores del motor con
## un cuerpo roto o que no es UTF-8).
static func parse_response(result: int, response_code: int, response_headers: PackedStringArray,
		body: PackedByteArray) -> ApiResult:
	if result != HTTPRequest.RESULT_SUCCESS:
		return ApiResult.no_response(ApiResult.CODE_NETWORK, PlatformErrors.TEXT_NETWORK)
	var parsed_result := ApiResult.new()
	parsed_result.status = response_code
	parsed_result.headers = response_headers
	if not body.is_empty() and NetMessages.is_valid_utf8(body, 0, body.size()):
		parsed_result.text = body.get_string_from_utf8()
	var parsed: Variant = null
	if not parsed_result.text.is_empty():
		var json := JSON.new()
		if json.parse(parsed_result.text) == OK:
			parsed = json.data
	if response_code >= 200 and response_code < 300:
		parsed_result.ok = true
		parsed_result.data = parsed if parsed is Dictionary else {}
		return parsed_result
	parsed_result.ok = false
	var error: Variant = (parsed as Dictionary).get("error") if parsed is Dictionary else null
	if error is Dictionary:
		parsed_result.data = error
		parsed_result.code = parsed_result.text_of("code")
		parsed_result.message = parsed_result.text_of("message")
		parsed_result.retry_after_s = maxi(parsed_result.int_of("retry_after_s", 0), 0)
	if parsed_result.code.is_empty():
		parsed_result.code = ApiResult.CODE_BAD_RESPONSE
	var retry_header: String = parsed_result.header("Retry-After")
	if parsed_result.retry_after_s == 0 and retry_header.is_valid_int():
		parsed_result.retry_after_s = maxi(retry_header.to_int(), 0)
	return parsed_result


# Un refresco, o el que ya vuela.
func _refresh() -> ApiResult:
	if _refreshing:
		await refreshed
		return _last_refresh
	_refreshing = true
	_refresh_count += 1
	var token: String = session.refresh_token
	var result: ApiResult
	if token.is_empty():
		result = ApiResult.failure(401, "unauthorized", "Tu sesión ha caducado")
	else:
		result = await _send(HTTPClient.METHOD_POST, REFRESH_PATH, {"refresh_token": token}, false)
	if result.ok and session.refresh_token == token:
		session.apply_tokens(result.data, now_msec())
	_last_refresh = result
	_refreshing = false
	if not result.ok and result.status == 401:
		session.clear()
		session_lost.emit(result.code)
	refreshed.emit(result.ok)
	return result


# Un intento: el gancho de las pruebas o la red.
func _send(method: HTTPClient.Method, path: String, body: Variant, auth: bool) -> ApiResult:
	if request_hook.is_valid():
		var hooked: Variant = await request_hook.call(method, path, body)
		if hooked is ApiResult:
			return hooked
		return ApiResult.no_response(ApiResult.CODE_BAD_RESPONSE, PlatformErrors.TEXT_INTERNAL)
	var url_error: String = ClientConfig.platform_url_error(base_url)
	if not url_error.is_empty():
		return ApiResult.no_response(ApiResult.CODE_BAD_URL, url_error)
	if not is_inside_tree():
		return ApiResult.no_response(ApiResult.CODE_NETWORK, PlatformErrors.TEXT_NETWORK)
	var http := HTTPRequest.new()
	http.name = "Llamada"
	http.use_threads = false
	http.accept_gzip = false
	http.timeout = timeout_s
	http.body_size_limit = MAX_RESPONSE_BYTES
	var tls: TLSOptions = _tls_options()
	if tls != null:
		http.set_tls_options(tls)
	add_child(http)
	var bytes := PackedByteArray()
	if body != null:
		bytes = JSON.stringify(body).to_utf8_buffer()
	var headers: PackedStringArray = request_headers(session.access_token if auth else "", body != null)
	var error: Error = http.request_raw(base_url.strip_edges().trim_suffix("/") + path, headers, method, bytes)
	if error != OK:
		http.queue_free()
		return ApiResult.no_response(ApiResult.CODE_NETWORK, PlatformErrors.TEXT_NETWORK)
	var response: Array = await http.request_completed
	http.queue_free()
	return parse_response(int(response[0]), int(response[1]), response[2] as PackedStringArray,
			response[3] as PackedByteArray)


# El certificado anclado del ajuste CA_CERT_SETTING, o null (los raíz de Godot).
static func _tls_options() -> TLSOptions:
	var path: String = str(ProjectSettings.get_setting(CA_CERT_SETTING, "")).strip_edges()
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var certificate := X509Certificate.new()
	if certificate.load(path) != OK:
		return null
	return TLSOptions.client(certificate)
