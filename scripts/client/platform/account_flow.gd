class_name AccountFlow
extends RefCounted
## El camino de la cuenta sin interfaz (docs/plataforma.md §13.3 y §14.4): iniciar sesión, asegurar el personaje y
## entrar al mundo, que devuelve el [ClientConfig] con billete para [OnlineMain]. Lo usan [FrontMain] (las pantallas)
## y [OnlineMain] en modo BOT con [code]--platform[/code] (el bot con cuenta, §5.5).
## [br][br]
## Todas las llamadas son corrutinas sobre [PlatformApi] y devuelven un [ApiResult]:
## [br]- [method login] guarda la [AccountSession] en [member PlatformApi.session].
## [br]- [method ensure_character] busca el personaje por nombre (con la clave de [NameRules]: «Anéira» es «aneira»)
## en el mundo y, si no está, lo crea con el pueblo de su reino, [method CharacterAppearance.default_for] y la primera
## plantilla de inicio por id ([method first_starter_template]); uno borrado que aún se puede restaurar se restaura.
## [code]data.character[/code] es el personaje y [code]data.created[/code] si se acaba de crear.
## [br]- [method enter] pide [code]enter[/code] y devuelve en [code]data.config[/code] un [ClientConfig] nuevo (copia
## del de partida) con la zona, el billete, el personaje y el certificado DTLS. Con [code]character_busy[/code] (el
## personaje aún sale del mundo, §5.3) reintenta cada [member busy_retry_s] s durante [member busy_timeout_s] s y
## avisa de cada espera con [signal busy_waiting]; [method cancel_enter] deja de esperar.
## [br][br]
## Los ids van como cadena en los cuerpos y se leen con [method parse_id] (§4.1). Solo cliente.

## El personaje aún está en el mundo: se volverá a pedir la entrada; quedan [param seconds_left] s de espera.
signal busy_waiting(seconds_left: int)

## Espera entre dos intentos de entrar con [code]character_busy[/code] (§5.3: cada 3 s durante 30 s).
const BUSY_RETRY_S: float = 3.0
const BUSY_TIMEOUT_S: float = 30.0
## Cifras de un id como mucho (2^63 − 1 tiene 19; con 18 nunca desborda [method String.to_int]).
const MAX_ID_DIGITS: int = 18
const _BASE64_PATTERN: String = "^[A-Za-z0-9+/]+={0,2}$"

var busy_retry_s: float = BUSY_RETRY_S
var busy_timeout_s: float = BUSY_TIMEOUT_S

var _api: PlatformApi = null
var _cancel_enter: bool = false

static var _base64: RegEx = null


func _init(api: PlatformApi) -> void:
	_api = api


func get_api() -> PlatformApi:
	return _api


## La sesión de la cuenta ([member PlatformApi.session]).
func get_session() -> AccountSession:
	return _api.session


## Inicia sesión con [param email] (sin espacios alrededor y en minúsculas, como lo guarda la plataforma) y
## [param password]. Si va bien, la sesión queda en [member PlatformApi.session] (también la de privacidad de una
## cuenta sancionada: [method AccountSession.is_privacy]). Corrutina.
func login(email: String, password: String) -> ApiResult:
	var body: Dictionary = {"email": email.strip_edges().to_lower(), "password": password}
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", body, false)
	if result.ok:
		_api.session = AccountSession.from_login(result.data, _api.now_msec())
	return result


## Cierra la sesión en la plataforma y la olvida aquí (aunque la llamada falle). Corrutina.
func logout() -> ApiResult:
	var result: ApiResult = ApiResult.success({}, 204)
	if _api.session.is_active():
		result = await _api.call_api(HTTPClient.METHOD_DELETE, "/v1/sessions/current", null, true)
	_api.session.clear()
	return result


## [code]GET /v1/account[/code]; si va bien, la cuenta queda en [member AccountSession.account]. Corrutina.
func fetch_account() -> ApiResult:
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account", null, true)
	if result.ok:
		_api.session.account = result.data
	return result


## Los personajes de la cuenta en [param world_id] ([code]{realm, unlock_at, slots, used, characters}[/code]).
## Corrutina.
func list_characters(world_id: int) -> ApiResult:
	return await _api.call_api(HTTPClient.METHOD_GET, "/v1/worlds/%d/characters" % world_id, null, true)


## Crea un personaje (§4.4): [param appearance] son los 8 B de [CharacterAppearance]. Corrutina.
func create_character(world_id: int, display_name: String, realm: StringName, race_id: StringName,
		appearance: PackedByteArray, starter_template_id: StringName) -> ApiResult:
	var body: Dictionary = {
		"name": display_name.strip_edges(),
		"realm": String(realm),
		"race_id": String(race_id),
		"appearance": Marshalls.raw_to_base64(appearance),
		"starter_template_id": String(starter_template_id),
	}
	return await _api.call_api(HTTPClient.METHOD_POST, "/v1/worlds/%d/characters" % world_id, body, true)


## El personaje [param display_name] de la cuenta en [param world_id]; si no existe, lo crea en [param realm] (id de
## [RealmCatalog]; vacío = el reino de la cuenta en ese mundo o, si aún no tiene, Vardheim). Corrutina.
func ensure_character(world_id: int, display_name: String, realm: StringName) -> ApiResult:
	var listed: ApiResult = await list_characters(world_id)
	if not listed.ok:
		return listed
	var key: String = NameRules.normalize_key(display_name.strip_edges())
	var characters: Variant = listed.data.get("characters", [])
	if characters is Array:
		for entry: Variant in characters:
			if not entry is Dictionary:
				continue
			var character: Dictionary = entry
			if NameRules.normalize_key(str(character.get("name", ""))) != key:
				continue
			if character.get("deleted_at") == null:
				return ApiResult.success({"character": character, "created": false})
			var restored: ApiResult = await _api.call_api(HTTPClient.METHOD_POST,
					"/v1/characters/%d/restore" % parse_id(character.get("character_id")), null, true)
			if not restored.ok:
				return restored
			return ApiResult.success({"character": restored.data.get("character", character), "created": false,
					"restored": true})
	var realm_id: StringName = realm
	if realm_id.is_empty():
		realm_id = StringName(listed.text_of("realm"))
	if not RealmCatalog.is_realm(realm_id):
		realm_id = RealmCatalog.VARDHEIM
	var created: ApiResult = await create_character(world_id, display_name, realm_id, race_id_for(realm_id),
			default_appearance(realm_id), first_starter_template())
	if not created.ok:
		return created
	return ApiResult.success({"character": created.data.get("character", {}), "created": true}, created.status)


## Pide entrar al mundo con [param character_id] y devuelve en [code]data.config[/code] la configuración de
## [OnlineMain] (una copia de [param base] con el billete). Reintenta [code]character_busy[/code] (§5.3). Corrutina.
func enter(character_id: int, base: ClientConfig) -> ApiResult:
	_cancel_enter = false
	var deadline_msec: int = _api.now_msec() + int(busy_timeout_s * 1000.0)
	while true:
		var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST,
				"/v1/characters/%d/enter" % character_id, null, true)
		if result.ok:
			var config: ClientConfig = config_from_enter(result.data, base)
			if config == null:
				return ApiResult.failure(result.status, ApiResult.CODE_BAD_RESPONSE, PlatformErrors.TEXT_INTERNAL)
			var answer: ApiResult = ApiResult.success({"config": config, "enter": result.data}, result.status)
			return answer
		if result.code != "character_busy" or _cancel_enter:
			return result
		var left_msec: int = deadline_msec - _api.now_msec()
		if left_msec <= 0 or not _api.is_inside_tree():
			return result
		busy_waiting.emit(ceili(float(left_msec) / 1000.0))
		var wait_s: float = minf(busy_retry_s, float(left_msec) / 1000.0)
		await _api.get_tree().create_timer(wait_s).timeout
		if _cancel_enter:
			return result
	return ApiResult.no_response()


## Deja de reintentar la entrada de [method enter] (la respuesta que espera es la última recibida).
func cancel_enter() -> void:
	_cancel_enter = true


## La configuración de [OnlineMain] de la respuesta de [code]enter[/code] ([param data], §4.5): copia de
## [param base] con la dirección y el puerto de la zona, el billete, el personaje (id, nombre y reino) y el
## certificado DTLS (o ninguno), sin plantilla de equipo ([member ClientConfig.loadout]: el kit lo decide la
## plataforma). Un modo sin red pasa a [constant ClientConfig.Mode.ONLINE]. Null si la respuesta no se entiende.
static func config_from_enter(data: Dictionary, base: ClientConfig) -> ClientConfig:
	var zone: Variant = data.get("zone")
	var character: Variant = data.get("character")
	var ticket_text: Variant = data.get("ticket")
	if not zone is Dictionary or not character is Dictionary or not ticket_text is String:
		return null
	var host: Variant = (zone as Dictionary).get("host")
	var port: Variant = (zone as Dictionary).get("port")
	if not host is String or (host as String).strip_edges().is_empty():
		return null
	if not (port is float or port is int) or float(port) != floorf(float(port)) or int(port) < 1 \
			or int(port) > 65535:
		return null
	var ticket: PackedByteArray = decode_base64(ticket_text)
	if ticket.is_empty() or ticket.size() > NetProtocol.MAX_TICKET_BYTES:
		return null
	var id: int = parse_id((character as Dictionary).get("character_id"))
	var display_name: Variant = (character as Dictionary).get("name")
	var realm_code: int = RealmCatalog.code_of(StringName(str((character as Dictionary).get("realm", ""))))
	if id <= 0 or not display_name is String or not RealmCatalog.is_realm_code(realm_code):
		return null
	var config: ClientConfig = (base if base != null else ClientConfig.new()).duplicate_config()
	config.address = (host as String).strip_edges()
	config.port = int(port)
	config.ticket = ticket
	config.character_id = id
	config.display_name = display_name
	config.realm = realm_code
	config.loadout = ""
	config.dtls_cert_pem = ""
	config.dtls_cert_path = ""
	config.dtls_name = ""
	var dtls: Variant = (zone as Dictionary).get("dtls")
	if dtls is Dictionary:
		config.dtls_cert_pem = str((dtls as Dictionary).get("cert_pem", ""))
		config.dtls_name = str((dtls as Dictionary).get("name", ""))
	if config.mode == ClientConfig.Mode.OFFLINE or config.mode == ClientConfig.Mode.TITLE:
		config.mode = ClientConfig.Mode.ONLINE
	return config


## Los bytes de un texto en base64 estándar (vacío si no lo es; sin registrar errores del motor).
static func decode_base64(text: Variant) -> PackedByteArray:
	if not text is String:
		return PackedByteArray()
	if _base64 == null:
		_base64 = RegEx.create_from_string(_BASE64_PATTERN)
	var clean: String = (text as String).strip_edges()
	if clean.is_empty() or clean.length() % 4 != 0 or _base64.search(clean) == null:
		return PackedByteArray()
	return Marshalls.base64_to_raw(clean)


## Un id de la API (§4.1: cadena decimal sin signo ni ceros a la izquierda) como entero; 0 si no lo es.
static func parse_id(value: Variant) -> int:
	if not value is String:
		return 0
	var text: String = value
	if text.is_empty() or text.length() > MAX_ID_DIGITS or (text.length() > 1 and text.begins_with("0")):
		return 0
	for i: int in range(text.length()):
		var c: int = text.unicode_at(i)
		if c < 48 or c > 57:
			return 0
	return text.to_int()


## El pueblo de [param realm_id] (id de [RealmCatalog]) en el catálogo de apariencia; [code]race_<reino>[/code] si
## el catálogo no lo tiene.
static func race_id_for(realm_id: StringName) -> StringName:
	var race: RaceDefinition = AppearanceCatalog.shared().race_for_realm(realm_id)
	return race.id if race != null else StringName("race_%s" % realm_id)


## Los 8 B de la apariencia por defecto del pueblo de [param realm_id] (8 ceros si no hay pueblo).
static func default_appearance(realm_id: StringName) -> PackedByteArray:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(realm_id)
	var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(race.id)) \
			if race != null else null
	if appearance == null:
		var empty := PackedByteArray()
		empty.resize(CharacterAppearance.ENCODED_SIZE)
		return empty
	return appearance.encode()


## Las plantillas de inicio que se pueden elegir al crear (las [EquipmentTemplate] con
## [member EquipmentTemplate.selectable], la sección [code]starter_templates[/code] de las reglas exportadas), por id.
static func starter_templates() -> Array[EquipmentTemplate]:
	var result: Array[EquipmentTemplate] = []
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if template != null and template.selectable:
			result.append(template)
	result.sort_custom(func(a: EquipmentTemplate, b: EquipmentTemplate) -> bool: return String(a.id) < String(b.id))
	return result


## La primera plantilla de inicio por id (la del bot y la que se marca al crear); [code]&""[/code] si no hay.
static func first_starter_template() -> StringName:
	var templates: Array[EquipmentTemplate] = starter_templates()
	return templates[0].id if not templates.is_empty() else &""
