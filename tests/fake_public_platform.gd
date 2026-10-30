class_name FakePublicPlatform
extends RefCounted
## La API pública de la plataforma de mentira para las pruebas del cliente (docs/plataforma.md §4 y §15 P8): el
## [member PlatformApi.request_hook] de [method hook] contesta lo de §4.2 a §4.5 con un estado en memoria (una cuenta,
## sus personajes, la entrada al mundo) y guarda cada llamada ([member calls]). Las respuestas se pueden guionizar por
## ruta con [method script_next] y retrasar con [member delay_s].
## [br][br]
## Los cuerpos son los de la plataforma de Go: ids en cadena, apariencia y billete en base64, reinos por su id de
## texto y fechas en Unix (§4.1).

## Una llamada recibida: [code]{method, path, body, token}[/code].
var calls: Array[Dictionary] = []
var email: String = "prueba@eldmark.test"
var password: String = "contraseña-larga"
## Ámbito y restricción del inicio de sesión ([code]privacy[/code] = cuenta sancionada).
var scope: String = "game"
var restriction: Variant = null
var account_realm: String = ""
var slots: int = 6
var characters: Array[Dictionary] = []
var next_character_id: int = 9007199254740993
var terms_required: bool = false
## La entrada al mundo: host, puerto, billete y DTLS (null = sin DTLS).
var zone_host: String = "127.0.0.1"
var zone_port: int = 24600
var ticket: PackedByteArray = PackedByteArray()
var dtls: Variant = null
## Respuestas character_busy que dará enter antes de dar el billete.
var busy_answers: int = 0
## Retraso de cada respuesta (s).
var delay_s: float = 0.0
var tree: SceneTree = null
var _scripted: Dictionary = {}
var _access_counter: int = 0


func _init(p_tree: SceneTree) -> void:
	tree = p_tree
	ticket.resize(52)
	for i: int in range(52):
		ticket[i] = i


## El gancho para [member PlatformApi.request_hook] de [param api] (que da el token de cada llamada).
func hook(api: PlatformApi) -> Callable:
	return func(method: int, path: String, body: Variant) -> ApiResult:
		calls.append({"method": method, "path": path, "body": body, "token": api.session.access_token})
		if delay_s > 0.0 and tree != null:
			await tree.create_timer(delay_s).timeout
		return answer(method, path, body)


## La próxima llamada a [param path] (que empieza por) recibe [param result], una vez.
func script_next(path: String, result: ApiResult) -> void:
	if not _scripted.has(path):
		_scripted[path] = []
	(_scripted[path] as Array).append(result)


## Las llamadas a rutas que empiezan por [param prefix] (con [param method], o con cualquiera si es −1).
func calls_to(prefix: String, method: int = -1) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for call: Dictionary in calls:
		if String(call["path"]).begins_with(prefix) and (method < 0 or int(call["method"]) == method):
			found.append(call)
	return found


## Un personaje como lo lista la plataforma.
func make_character(display_name: String, realm: String = "vardheim", level: int = 1,
		deleted: bool = false) -> Dictionary:
	var id: int = next_character_id
	next_character_id += 1
	var appearance: PackedByteArray = AccountFlow.default_appearance(StringName(realm))
	var character: Dictionary = {
		"character_id": str(id), "name": display_name, "realm": realm, "race_id": "race_%s" % realm,
		"appearance": Marshalls.raw_to_base64(appearance), "level": level, "last_zone_id": "vado_gris",
		"played_seconds": 120, "created_at": 1800000000, "deleted_at": 1800000500 if deleted else null,
		"restore_until": 1800600000 if deleted else null, "must_rename": false,
	}
	characters.append(character)
	if account_realm.is_empty():
		account_realm = realm
	return character


func answer(method: int, path: String, body: Variant) -> ApiResult:
	for prefix: Variant in _scripted:
		if path.begins_with(str(prefix)) and not (_scripted[prefix] as Array).is_empty():
			return (_scripted[prefix] as Array).pop_front()
	var data: Dictionary = body if body is Dictionary else {}
	match [method, path]:
		[HTTPClient.METHOD_GET, "/v1/status"]:
			return ApiResult.success({"status": "ok", "message": "", "maintenance_at": null, "min_protocol": 7,
					"worlds": [{"world_id": 1, "name": "Eld", "status": "ok", "load": "low"}],
					"news": [{"title": "Pruebas", "body": "Abiertas", "date": 1800000000}]})
		[HTTPClient.METHOD_GET, "/v1/legal"]:
			return ApiResult.success({"terms": {"version": 1, "sha256": "aa"}, "privacy": {"version": 2, "sha256": "bb"},
					"rules": {"version": 1, "sha256": "cc"}})
		[HTTPClient.METHOD_POST, "/v1/sessions"]:
			if data.get("email") != email or data.get("password") != password:
				return ApiResult.failure(401, "invalid_credentials", "Correo o contraseña incorrectos")
			_access_counter += 1
			return ApiResult.success({"access_token": "acceso-%d" % _access_counter, "access_expires_in": 900,
					"refresh_token": "refresco-%d" % _access_counter, "refresh_expires_in": 43200, "scope": scope,
					"restriction": restriction, "account": _account()})
		[HTTPClient.METHOD_DELETE, "/v1/sessions/current"]:
			return ApiResult.success({}, 204)
		[HTTPClient.METHOD_GET, "/v1/account"]:
			return ApiResult.success(_account())
		[HTTPClient.METHOD_POST, "/v1/account/accept"]:
			terms_required = false
			return ApiResult.success({}, 204)
		[HTTPClient.METHOD_POST, "/v1/accounts"]:
			return ApiResult.success({}, 202)
		[HTTPClient.METHOD_POST, "/v1/account/password-reset"]:
			return ApiResult.success({}, 202)
	if path.begins_with("/v1/legal/"):
		var text_result := ApiResult.success({})
		text_result.text = "# Texto de %s\n\nBorrador." % path.get_file()
		return text_result
	if path.begins_with("/v1/worlds/1/name-check"):
		var query_name: String = path.get_slice("name=", 1).uri_decode()
		for character: Dictionary in characters:
			if NameRules.normalize_key(str(character["name"])) == NameRules.normalize_key(query_name):
				return ApiResult.success({"available": false, "code": "name_taken", "reason": ""})
		return ApiResult.success({"available": true, "code": "", "reason": ""})
	if path == "/v1/worlds/1/characters" and method == HTTPClient.METHOD_GET:
		return ApiResult.success({"realm": account_realm if not account_realm.is_empty() else null,
				"unlock_at": null, "slots": slots, "used": characters.size(), "characters": characters.duplicate(true)})
	if path == "/v1/worlds/1/characters" and method == HTTPClient.METHOD_POST:
		var created: Dictionary = make_character(str(data.get("name", "")), str(data.get("realm", "vardheim")))
		created["appearance"] = data.get("appearance")
		created["race_id"] = data.get("race_id")
		return ApiResult.success({"character": created}, 201)
	var id: int = AccountFlow.parse_id(path.get_slice("/", 3))
	var character: Dictionary = _find(id)
	if path.begins_with("/v1/characters/"):
		if character.is_empty():
			return ApiResult.failure(404, "not_found", "No encontrado")
		if path.ends_with("/enter"):
			if terms_required:
				return ApiResult.failure(403, "terms_required", "Textos por aceptar", {"documents": ["privacy"]})
			if bool(character.get("must_rename", false)):
				return ApiResult.failure(409, "rename_required", "Renombrado")
			if busy_answers > 0:
				busy_answers -= 1
				return ApiResult.failure(409, "character_busy", "Ocupado", {}, 3)
			return ApiResult.success({"zone": {"zone_id": "test_world", "channel": 0, "host": zone_host,
					"port": zone_port, "dtls": dtls}, "ticket": Marshalls.raw_to_base64(ticket), "expires_in_s": 10,
					"character": {"character_id": str(id), "name": character["name"], "realm": character["realm"]}})
		if path.ends_with("/restore"):
			character["deleted_at"] = null
			character["restore_until"] = null
			return ApiResult.success({"character": character})
		if path.ends_with("/rename"):
			character["name"] = data.get("name")
			character["must_rename"] = false
			return ApiResult.success({"character": character})
		if method == HTTPClient.METHOD_DELETE:
			if NameRules.normalize_key(str(data.get("confirm_name", ""))) != NameRules.normalize_key(str(character["name"])):
				return ApiResult.failure(400, "validation", "Datos no válidos", {"fields": {"confirm_name": "mismatch"}})
			character["deleted_at"] = 1800000500
			character["restore_until"] = 1800600000
			return ApiResult.success({"restore_until": 1800600000})
	return ApiResult.failure(404, "not_found", "No encontrado")


func _find(id: int) -> Dictionary:
	for character: Dictionary in characters:
		if AccountFlow.parse_id(character.get("character_id")) == id:
			return character
	return {}


func _account() -> Dictionary:
	return {"account_id": "42", "email": email, "email_verified": true, "role": "player",
			"realms": {"1": account_realm} if not account_realm.is_empty() else {}, "slots": {"1": slots},
			"consents": {"crash_reports": false, "analytics": false},
			"pending": {"terms_required": terms_required, "documents": ["privacy"] if terms_required else [],
					"deletion_at": null}, "restriction": restriction}
