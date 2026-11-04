class_name PlatformApi
extends Node
## Client of the platform's public API (docs/plataforma.md §4 and §14.4): HTTPS and JSON with the headers from
## §4.1 ([code]Authorization[/code], [code]X-Eldmark-Protocol[/code] and [code]X-Eldmark-Build[/code]).
## [br][br]
## [method call_api] is a coroutine that returns an [ApiResult]:
## [codeblock]
## var result: ApiResult = await api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", {…}, false)
## [/codeblock]
## [b]Session.[/b] Calls with a session ([param auth]) carry the access token from [member session]. If it expires in
## less than a minute it is refreshed first; if the platform answers 401 [code]unauthorized[/code] it is refreshed once and
## the call is repeated. [b]Only one refresh in flight[/b] (§4.2): calls that need it at the same time wait for the
## same one ([signal refreshed] signal), so the platform never sees two refreshes with the same token, which it would take for
## reuse and would close the session. If the refresh gives 401, the session is forgotten and [signal session_lost] is emitted: whoever
## shows the UI returns to the title screen.
## [br][br]
## [b]Transport.[/b] One [HTTPRequest] per call (in the tree: this node must be in it), with a
## [member timeout_s] timeout. Only [code]https://[/code] or, towards this machine, [code]http://[/code]
## ([method ClientConfig.platform_url_error]); with the [constant CA_CERT_SETTING] setting (path to a PEM) that
## certificate is pinned (staging with its own certificate, §10.1). A body that is not UTF-8 or JSON never logs engine
## errors. Ids always go as strings (§4.1): whoever builds a body sets them with [code]str()[/code].
## [br][br]
## [b]Tests.[/b] [member request_hook] replaces the transport: it receives [code](method, path, body)[/code] and returns an
## [ApiResult] (it may be a coroutine, to simulate a slow response). Everything else (refresh, retry after
## the 401, [signal session_lost]) runs the same. Client only.

## Refreshing is impossible (the session is no longer valid): the UI returns to the title screen. [param code] is the error's.
signal session_lost(code: String)
## A refresh has finished ([param ok]: whether it went well). Internal: calls that arrive while it is in flight wait for it.
signal refreshed(ok: bool)

## Timeout of each request (s).
const TIMEOUT_S: float = 15.0
## Maximum size of a response (the data export is the largest).
const MAX_RESPONSE_BYTES: int = 8 * 1024 * 1024
const REFRESH_PATH: String = "/v1/sessions/refresh"
## Project setting with the path of a PEM certificate to pin (empty = Godot's roots).
const CA_CERT_SETTING: String = "eldmark/platform/ca_cert"
const PROTOCOL_HEADER: String = "X-Eldmark-Protocol"
const BUILD_HEADER: String = "X-Eldmark-Build"

## Base URL of the public API ([code]https://cuentas.eldmark.example[/code], without a trailing slash).
var base_url: String = ""
## Tests: [code](method: int, path: String, body: Variant) -> ApiResult[/code] instead of the network.
var request_hook: Callable = Callable()
## The account session (set by [AccountFlow] on login).
var session: AccountSession = AccountSession.new()
## Timeout of each request (s).
var timeout_s: float = TIMEOUT_S
## Tests: [code]() -> int[/code] with the time in ms instead of [method Time.get_ticks_msec].
var clock: Callable = Callable()

var _refreshing: bool = false
var _last_refresh: ApiResult = null
var _refresh_count: int = 0
var _calls: int = 0


func _init() -> void:
	name = "PlatformApi"


## Calls [param path] (with the [code]/v1[/code] prefix) with [param method] and the body [param body] (a dictionary
## sent as JSON; null = no body). With [param auth], with the session (and its refresh). Coroutine.
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
		# If another call already refreshed while this one was in flight, it is enough to repeat with the new token.
		if session.access_token == sent_token:
			var refresh: ApiResult = await _refresh()
			if not refresh.ok:
				return refresh if refresh.status != 401 else result
		if not session.is_active():
			return result
		result = await _send(method, path, body, auth)
	return result


## Refreshes done since this node has existed (tests: two calls that expire at the same time make one).
func get_refresh_count() -> int:
	return _refresh_count


## Calls to [method call_api] since this node has existed.
func get_call_count() -> int:
	return _calls


## true while a refresh is in flight.
func is_refreshing() -> bool:
	return _refreshing


## The time (ms) against which the session's deadlines are checked.
func now_msec() -> int:
	if clock.is_valid():
		return int(clock.call())
	return Time.get_ticks_msec()


## Identifier of this client version for [constant BUILD_HEADER]: [code]eldmark-<version>-p<protocol>[/code]
## (the same format as the zones' registration).
static func build_id() -> String:
	var version: String = str(ProjectSettings.get_setting("application/config/version", "0"))
	return ("eldmark-%s-p%d" % [version, NetProtocol.PROTOCOL_VERSION]).replace(" ", "_").left(64)


## The headers of a request with the token [param access_token] (empty = no session) and with or without a body.
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


## Converts what [signal HTTPRequest.request_completed] gives into an [ApiResult] (without logging engine errors with
## a broken body or one that is not UTF-8).
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


# A refresh, or the one already in flight.
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


# One attempt: the tests' hook or the network.
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


# The pinned certificate from the CA_CERT_SETTING setting, or null (Godot's roots).
static func _tls_options() -> TLSOptions:
	var path: String = str(ProjectSettings.get_setting(CA_CERT_SETTING, "")).strip_edges()
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var certificate := X509Certificate.new()
	if certificate.load(path) != OK:
		return null
	return TLSOptions.client(certificate)
