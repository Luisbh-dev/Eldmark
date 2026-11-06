extends TestCase
## Tests of [PlatformApi], [ApiResult], [AccountSession] and [PlatformErrors] (docs/platform.md §4.1, §4.2, §14.4 and
## §15 P8): the refresh on a 401 with the call repeated, [b]a single refresh[/b] for two calls that expire at
## the same time (before going out or with the 401 on both), the lost session, the error map, odd responses without
## engine errors and, with [FakeHttpServer], the §4.1 headers and the bodies over real HTTP.

const OLD_ACCESS: String = "acceso-viejo"
const NEW_ACCESS: String = "acceso-nuevo"
const OLD_REFRESH: String = "refresco-viejo"
const NEW_REFRESH: String = "refresco-nuevo"

var _api: PlatformApi
var _http: FakeHttpServer
var _calls: Array[String] = []
var _lost: Array[String] = []
var _now_msec: int = 1000000


func before_each() -> void:
	_calls.clear()
	_lost.clear()
	_now_msec = 1000000
	_api = PlatformApi.new()
	_api.clock = func() -> int: return _now_msec
	tree.root.add_child(_api)
	_api.session_lost.connect(func(code: String) -> void: _lost.append(code))


func after_each() -> void:
	if is_instance_valid(_api):
		_api.free()
	_api = null
	if is_instance_valid(_http):
		_http.stop()
		_http.free()
	_http = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## A session with an [param access] token that expires within [param expires_in_s] s.
func _login(access: String = OLD_ACCESS, expires_in_s: int = 900) -> void:
	_api.session = AccountSession.from_login({"access_token": access, "access_expires_in": expires_in_s,
			"refresh_token": OLD_REFRESH, "refresh_expires_in": 43200, "scope": "game", "restriction": null,
			"account": {"account_id": "7", "realms": {"1": "vardheim"}}}, _now_msec)


## The fake platform: the refresh takes [param refresh_delay_s] and gives the new tokens (or [param refresh_answer]);
## a call with the old token gets 401 if [param old_is_rejected]; the rest, 200 with the path.
func _hook(refresh_delay_s: float = 0.0, old_is_rejected: bool = false,
		refresh_answer: ApiResult = null) -> Callable:
	return func(method: int, path: String, body: Variant) -> ApiResult:
		_calls.append("%d %s" % [method, path])
		if path == PlatformApi.REFRESH_PATH:
			if refresh_delay_s > 0.0:
				await tree.create_timer(refresh_delay_s).timeout
			if refresh_answer != null:
				return refresh_answer
			if (body as Dictionary).get("refresh_token") != OLD_REFRESH:
				return ApiResult.failure(401, "unauthorized", "Tu sesión ha caducado")
			return ApiResult.success({"access_token": NEW_ACCESS, "access_expires_in": 900,
					"refresh_token": NEW_REFRESH, "refresh_expires_in": 40000, "scope": "game"})
		if old_is_rejected and _api.session.access_token == OLD_ACCESS:
			# The two calls at once: the 401 arrives when both have already been sent.
			await tree.create_timer(0.05).timeout
			return ApiResult.failure(401, "unauthorized", "Tu sesión ha caducado")
		return ApiResult.success({"path": path, "token": _api.session.access_token})


func _count(prefix: String) -> int:
	var total: int = 0
	for call: String in _calls:
		if call.contains(prefix):
			total += 1
	return total


func _wait_until(condition: Callable, max_frames: int = 300) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await wait_process_frames()
	return condition.call()


# --- Refresh ----------------------------------------------------------------------------------

func test_a_401_refreshes_once_and_repeats_the_call() -> void:
	_login()
	_api.request_hook = func(method: int, path: String, body: Variant) -> ApiResult:
		_calls.append("%d %s" % [method, path])
		if path == PlatformApi.REFRESH_PATH:
			return ApiResult.success({"access_token": NEW_ACCESS, "access_expires_in": 900,
					"refresh_token": NEW_REFRESH, "refresh_expires_in": 40000, "scope": "game"})
		if _api.session.access_token == OLD_ACCESS:
			return ApiResult.failure(401, "unauthorized", "Tu sesión ha caducado")
		return ApiResult.success({"token": _api.session.access_token, "body": body})
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account")
	assert_true(result.ok, "the repeated call goes well: %s" % result)
	assert_eq(result.data.get("token"), NEW_ACCESS, "with the new token")
	assert_eq(_calls, ["%d /v1/account" % HTTPClient.METHOD_GET,
			"%d %s" % [HTTPClient.METHOD_POST, PlatformApi.REFRESH_PATH], "%d /v1/account" % HTTPClient.METHOD_GET])
	assert_eq(_api.get_refresh_count(), 1)
	assert_eq(_api.session.refresh_token, NEW_REFRESH, "the refresh rotates both tokens")
	assert_eq(_api.session.scope, "game", "and keeps the scope")
	assert_true(_lost.is_empty())


func test_an_access_token_about_to_expire_is_refreshed_before_the_call() -> void:
	_login(OLD_ACCESS, 30)
	assert_true(_api.session.needs_refresh(_now_msec), "less than 60 s from expiring")
	_api.request_hook = _hook()
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/worlds/1/characters")
	assert_true(result.ok)
	assert_eq(result.data.get("token"), NEW_ACCESS, "the call already goes out with the new token")
	assert_eq(_count(PlatformApi.REFRESH_PATH), 1)
	assert_eq(_count("/characters"), 1, "and only once")


func test_two_calls_that_expire_at_once_make_a_single_refresh() -> void:
	_login(OLD_ACCESS, 30)
	_api.request_hook = _hook(0.15)
	var results: Array[ApiResult] = []
	var run: Callable = func(path: String) -> void:
		results.append(await _api.call_api(HTTPClient.METHOD_GET, path))
	run.call("/v1/account")
	run.call("/v1/worlds/1/characters")
	assert_true(_api.is_refreshing(), "the refresh is in flight")
	assert_true(await _wait_until(func() -> bool: return results.size() == 2), "both finish")
	assert_eq(_count(PlatformApi.REFRESH_PATH), 1, "a single refresh: %s" % [_calls])
	assert_eq(_api.get_refresh_count(), 1)
	for result: ApiResult in results:
		assert_true(result.ok, "%s" % result)
		assert_eq(result.data.get("token"), NEW_ACCESS, "both with the new token")
	assert_true(_lost.is_empty(), "the session is not lost")


func test_two_calls_rejected_with_401_at_once_make_a_single_refresh() -> void:
	_login()
	_api.request_hook = _hook(0.1, true)
	var results: Array[ApiResult] = []
	var run: Callable = func(path: String) -> void:
		results.append(await _api.call_api(HTTPClient.METHOD_GET, path))
	run.call("/v1/account")
	run.call("/v1/worlds/1/characters")
	assert_true(await _wait_until(func() -> bool: return results.size() == 2), "both finish")
	assert_eq(_count(PlatformApi.REFRESH_PATH), 1, "a single refresh even though both received 401: %s" % [_calls])
	for result: ApiResult in results:
		assert_true(result.ok, "repeated with the new token: %s" % result)
	assert_eq(_count("/v1/account"), 2, "each one is repeated once")


func test_a_rejected_refresh_loses_the_session() -> void:
	_login()
	_api.request_hook = _hook(0.0, true, ApiResult.failure(401, "unauthorized", "Tu sesión ha caducado"))
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account")
	assert_false(result.ok)
	assert_eq(result.code, "unauthorized")
	assert_eq(_lost, ["unauthorized"], "session_lost is emitted once")
	assert_false(_api.session.is_active(), "and the session is forgotten")
	var again: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account")
	assert_eq(again.status, 401, "without a session, the call does not go out")
	assert_eq(_count("/v1/account"), 1)


func test_a_refresh_without_answer_keeps_the_session() -> void:
	_login(OLD_ACCESS, 30)
	_api.request_hook = _hook(0.0, false, ApiResult.no_response())
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account")
	assert_false(result.ok)
	assert_eq(result.code, ApiResult.CODE_NETWORK)
	assert_eq(PlatformErrors.text_for(result), "No se puede conectar con el servidor de cuentas")
	assert_true(_lost.is_empty(), "without a network the session is not considered lost")
	assert_true(_api.session.is_active())


func test_calls_without_session_and_public_calls() -> void:
	_api.request_hook = _hook()
	var private_call: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account")
	assert_eq(private_call.status, 401)
	assert_eq(private_call.code, "unauthorized")
	assert_true(_calls.is_empty(), "a call that needs a session does not go out without one")
	var public_call: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/status", null, false)
	assert_true(public_call.ok, "a public one does")
	assert_eq(_api.get_refresh_count(), 0)


# --- Session ------------------------------------------------------------------------------------

func test_account_session_from_login() -> void:
	var session: AccountSession = AccountSession.from_login({"access_token": "a", "access_expires_in": 900.0,
			"refresh_token": "r", "refresh_expires_in": 43200, "scope": "privacy",
			"restriction": {"code": "account_banned", "until": null, "reason": "Trampas"},
			"account": {"account_id": "9007199254740993", "realms": {"1": "solmarch"}}}, 5000)
	assert_true(session.is_active())
	assert_true(session.is_privacy())
	assert_eq(session.access_expires_msec, 5000 + 900000)
	assert_eq(session.refresh_expires_msec, 5000 + 43200000)
	assert_eq(session.restriction.get("code"), "account_banned")
	assert_eq(session.realm_in(1), &"solmarch")
	assert_eq(session.realm_in(2), &"", "without a realm in that world")
	assert_false(session.needs_refresh(5000 + 900000 - 60001), "more than a minute from expiring")
	assert_true(session.needs_refresh(5000 + 900000 - 60000), "at one minute")
	assert_true(session.needs_refresh(5000 + 900000 + 1), "already expired")
	session.clear()
	assert_false(session.is_active())
	assert_false(session.needs_refresh(0), "without a session there is nothing to refresh")
	assert_true(session.account.is_empty() and session.restriction.is_empty())


# --- Errors -------------------------------------------------------------------------------------

func test_the_error_map_of_section_4_1() -> void:
	var cases: Array[Array] = [
		[ApiResult.failure(401, "invalid_credentials", "x"), "Correo o contraseña incorrectos"],
		[ApiResult.failure(401, "unauthorized", "x"), "Tu sesión ha caducado"],
		[ApiResult.failure(409, "name_taken", "x"), "Ese nombre ya está en uso"],
		[ApiResult.failure(409, "slots_full", "x"), "No te quedan huecos"],
		[ApiResult.failure(409, "realm_closed", "x"), "Ese reino abre más adelante"],
		[ApiResult.failure(409, "character_busy", "x", {}, 3), "Tu personaje está saliendo del mundo…"],
		[ApiResult.failure(426, "client_outdated", "x", {"min_protocol": 8}), "Actualiza el cliente"],
		[ApiResult.failure(429, "rate_limited", "x", {}, 42), "Demasiados intentos; espera 42 s"],
		[ApiResult.failure(503, "zone_unavailable", "x"), "La zona no está disponible"],
		[ApiResult.failure(503, "maintenance", "Volvemos a las 18:00"), "Volvemos a las 18:00"],
		[ApiResult.failure(403, "email_unverified", "x"), "Verifica tu correo para entrar"],
		[ApiResult.failure(400, "validation", "x", {"fields": {"password": "short", "email": "invalid"}}),
				"Datos no válidos (correo, contraseña)"],
		[ApiResult.failure(400, "validation", "x", {"fields": {"accept.terms": "outdated"}}),
				"Datos no válidos (textos legales)"],
		[ApiResult.failure(400, "bad_request", "x"), "Datos no válidos"],
		[ApiResult.failure(422, "name_invalid", "x", {"reason": "has_digit"}),
				NameRules.reason_text(NameRules.Reason.HAS_DIGIT)],
		[ApiResult.failure(409, "realm_locked", "x", {"realm": "vardheim", "unlock_at": null}),
				"Tu cuenta es de Vardheim"],
		[ApiResult.failure(403, "account_banned", "x", {"reason": "Trampas", "until": null}),
				"Cuenta expulsada: Trampas"],
		[ApiResult.failure(500, "internal", "x"), "Error del servidor"],
		[ApiResult.failure(418, "codigo_nuevo", "Un mensaje del servidor"), "Un mensaje del servidor"],
		[ApiResult.no_response(), "No se puede conectar con el servidor de cuentas"],
	]
	for entry: Array in cases:
		assert_eq(PlatformErrors.text_for(entry[0] as ApiResult), entry[1], "text of %s" % entry[0])
	var suspended: String = PlatformErrors.text_for(ApiResult.failure(403, "account_suspended", "x",
			{"until": 1800000000, "reason": "Insultos"}))
	assert_true(suspended.begins_with("Cuenta suspendida hasta el ") and suspended.ends_with(": Insultos"),
			suspended)
	assert_true(suspended.contains("/2027"), "with the date: %s" % suspended)
	var deletion: String = PlatformErrors.text_for(ApiResult.failure(403, "account_pending_deletion", "x",
			{"deletion_at": 1800000000}))
	assert_true(deletion.begins_with("Tu cuenta se borrará el "), deletion)
	assert_eq(PlatformErrors.text_for(ApiResult.success()), "", "without an error, without text")


func test_odd_responses_never_log_engine_errors() -> void:
	var no_content: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_SUCCESS, 204, PackedStringArray(),
			PackedByteArray())
	assert_true(no_content.ok)
	assert_true(no_content.data.is_empty())
	var broken: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
			"{\"a\":".to_utf8_buffer())
	assert_true(broken.ok, "a 200 with a broken body is a 200")
	assert_true(broken.data.is_empty())
	var not_utf8: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_SUCCESS, 500, PackedStringArray(),
			PackedByteArray([0xff, 0xfe, 0x7b]))
	assert_false(not_utf8.ok)
	assert_eq(not_utf8.code, ApiResult.CODE_BAD_RESPONSE)
	assert_eq(not_utf8.text, "", "what is not UTF-8 is not read")
	var markdown: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_SUCCESS, 200,
			PackedStringArray(["Content-Type: text/markdown"]), "# Términos\n\nTexto".to_utf8_buffer())
	assert_true(markdown.ok)
	assert_eq(markdown.text, "# Términos\n\nTexto", "a text that is not JSON stays in text")
	var limited: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_SUCCESS, 429,
			PackedStringArray(["Retry-After: 17"]), JSON.stringify({"error": {"code": "rate_limited",
			"message": "Demasiados intentos"}}).to_utf8_buffer())
	assert_eq(limited.code, "rate_limited")
	assert_eq(limited.retry_after_s, 17, "from the Retry-After header if the body does not carry it")
	assert_eq(limited.header("retry-after"), "17")
	var error: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_SUCCESS, 409, PackedStringArray(),
			JSON.stringify({"error": {"code": "character_busy", "message": "Ocupado", "retry_after_s": 3}})
			.to_utf8_buffer())
	assert_eq(error.code, "character_busy")
	assert_eq(error.message, "Ocupado")
	assert_eq(error.retry_after_s, 3)
	assert_eq(error.data.get("code"), "character_busy", "data is the error object")
	var refused: ApiResult = PlatformApi.parse_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(),
			PackedByteArray())
	assert_eq(refused.status, 0)
	assert_eq(refused.code, ApiResult.CODE_NETWORK)


# --- Real HTTP ----------------------------------------------------------------------------------

func _start_http() -> void:
	_http = FakeHttpServer.new()
	_http.name = "FakeHttpServer"
	tree.root.add_child(_http)
	assert_true(_http.listen() > 0, "the fake HTTP server listens")
	_api.base_url = _http.base_url()


func test_requests_carry_the_headers_of_section_4_1() -> void:
	_start_http()
	_login()
	_http.script("POST", "/v1/worlds/1/characters", 201, {"character": {"character_id": "9007199254740993",
			"name": "Aneira"}})
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/worlds/1/characters",
			{"name": "Aneira", "realm": "vardheim"})
	assert_true(result.ok, "%s" % result)
	assert_eq(result.status, 201)
	assert_eq((result.data.get("character") as Dictionary).get("character_id"), "9007199254740993",
			"the ids arrive as a string, integers")
	var received: Array[FakeHttpServer.Received] = _http.requests_to("POST", "/v1/worlds/1/characters")
	if not assert_eq(received.size(), 1):
		return
	var request: FakeHttpServer.Received = received[0]
	assert_eq(request.headers.get("authorization"), "Bearer %s" % OLD_ACCESS)
	assert_eq(request.headers.get("x-eldmark-protocol"), str(NetProtocol.PROTOCOL_VERSION))
	assert_eq(request.headers.get("x-eldmark-build"), PlatformApi.build_id())
	assert_true(PlatformApi.build_id().begins_with("eldmark-") and PlatformApi.build_id().contains(
			"-p%d+" % NetProtocol.PROTOCOL_VERSION))
	assert_eq(request.headers.get("content-type"), "application/json")
	assert_eq(request.json(), {"name": "Aneira", "realm": "vardheim"})
	_http.script("GET", "/v1/status", 200, {"status": "ok"})
	var status: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/status", null, false)
	assert_true(status.ok)
	var public_request: FakeHttpServer.Received = _http.requests_to("GET", "/v1/status")[0]
	assert_false(public_request.headers.has("authorization"), "a public call does not carry the token")
	assert_eq(public_request.headers.get("x-eldmark-protocol"), str(NetProtocol.PROTOCOL_VERSION),
			"but it does carry the protocol")
	assert_false(public_request.headers.has("content-type"), "without a body, without Content-Type")


func test_errors_and_text_bodies_over_http() -> void:
	_start_http()
	_http.script("POST", "/v1/sessions", 401, {"error": {"code": "invalid_credentials",
			"message": "Correo o contraseña incorrectos", "retry_after_s": 0}})
	_http.script("GET", "/v1/legal/terms", 200, "# Términos de uso\n\nBorrador")
	_http.script("GET", "/v1/status", 503, "")
	var login: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/sessions",
			{"email": "a@b.c", "password": "x"}, false)
	assert_false(login.ok)
	assert_eq(login.status, 401)
	assert_eq(login.code, "invalid_credentials")
	assert_eq(_lost, [], "the 401 of a public call neither refreshes nor loses anything")
	var legal: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/legal/terms", null, false)
	assert_true(legal.ok)
	assert_eq(legal.text, "# Términos de uso\n\nBorrador")
	var down: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/status", null, false)
	assert_eq(down.status, 503)
	assert_eq(down.code, ApiResult.CODE_BAD_RESPONSE, "an error without a body")
	assert_eq(PlatformErrors.text_for(down), "Error del servidor")


func test_an_insecure_url_is_refused_before_any_request() -> void:
	_api.base_url = "http://cuentas.eldmark.example"
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/status", null, false)
	assert_false(result.ok)
	assert_eq(result.code, ApiResult.CODE_BAD_URL)
	assert_true(PlatformErrors.text_for(result).contains("https://"), PlatformErrors.text_for(result))
	assert_eq(_api.get_child_count(), 0, "no request is created")


func test_a_platform_that_does_not_answer_is_a_network_error() -> void:
	_api.base_url = "http://127.0.0.1:%d" % NetHarness.free_udp_port()
	_api.timeout_s = 2.0
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/status", null, false)
	assert_false(result.ok)
	assert_eq(result.status, 0)
	assert_eq(result.code, ApiResult.CODE_NETWORK)
