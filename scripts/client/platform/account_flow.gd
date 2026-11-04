class_name AccountFlow
extends RefCounted
## The UI-less account path (docs/plataforma.md §13.3 and §14.4): logging in, ensuring the character and
## entering the world, which returns the [ClientConfig] with a ticket for [OnlineMain]. It is used by [FrontMain] (the screens)
## and by [OnlineMain] in BOT mode with [code]--platform[/code] (the bot with an account, §5.5).
## [br][br]
## All calls are coroutines on [PlatformApi] and return an [ApiResult]:
## [br]- [method login] stores the [AccountSession] in [member PlatformApi.session].
## [br]- [method ensure_character] looks for the character by name (using the [NameRules] key: "Anéira" is "aneira")
## in the world and, if absent, creates it with its realm's people, [method CharacterAppearance.default_for] and the
## requested starter template (the bot's [code]--loadout[/code]) or, without one, the first by id
## ([method first_starter_template]); a deleted one that can still be restored is restored.
## [code]data.character[/code] is the character and [code]data.created[/code] whether it was just created.
## [br]- [method enter] requests [code]enter[/code] and returns in [code]data.config[/code] a new [ClientConfig] (a copy
## of the starting one) with the zone, ticket, character and DTLS certificate. With [code]character_busy[/code] (the
## character is still leaving the world, §5.3) it retries every [member busy_retry_s] s for [member busy_timeout_s] s and
## reports each wait with [signal busy_waiting]; [method cancel_enter] stops waiting.
## [br][br]
## Ids go as strings in the bodies and are read with [method parse_id] (§4.1). Client only.

## The character is still in the world: entry will be requested again; [param seconds_left] s of waiting remain.
signal busy_waiting(seconds_left: int)

## Wait between two attempts to enter with [code]character_busy[/code] (§5.3: every 3 s for 30 s).
const BUSY_RETRY_S: float = 3.0
const BUSY_TIMEOUT_S: float = 30.0
## Maximum digits of an id (2^63 − 1 has 19; with 18 it never overflows [method String.to_int]).
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


## The account session ([member PlatformApi.session]).
func get_session() -> AccountSession:
	return _api.session


## Logs in with [param email] (without surrounding spaces and in lowercase, as the platform stores it) and
## [param password]. If it goes well, the session is stored in [member PlatformApi.session] (also the privacy session of a
## sanctioned account: [method AccountSession.is_privacy]). Coroutine.
func login(email: String, password: String) -> ApiResult:
	var body: Dictionary = {"email": email.strip_edges().to_lower(), "password": password}
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/sessions", body, false)
	if result.ok:
		_api.session = AccountSession.from_login(result.data, _api.now_msec())
	return result


## Closes the session on the platform and forgets it here (even if the call fails). Coroutine.
func logout() -> ApiResult:
	var result: ApiResult = ApiResult.success({}, 204)
	if _api.session.is_active():
		result = await _api.call_api(HTTPClient.METHOD_DELETE, "/v1/sessions/current", null, true)
	_api.session.clear()
	return result


## [code]GET /v1/account[/code]; if it goes well, the account is stored in [member AccountSession.account]. Coroutine.
func fetch_account() -> ApiResult:
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/account", null, true)
	if result.ok:
		_api.session.account = result.data
	return result


## The account's characters in [param world_id] ([code]{realm, unlock_at, slots, used, characters}[/code]).
## Coroutine.
func list_characters(world_id: int) -> ApiResult:
	return await _api.call_api(HTTPClient.METHOD_GET, "/v1/worlds/%d/characters" % world_id, null, true)


## Creates a character (§4.4): [param appearance] is the 8 B of [CharacterAppearance]. Coroutine.
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


## The account's character [param display_name] in [param world_id]; if it does not exist, creates it in [param realm] (id from
## [RealmCatalog]; empty = the account's realm in that world or, if it has none yet, Vardheim) with the starter template
## [param starter_template] (empty, or a non-selectable one = [method first_starter_template]; docs/progresion.md
## §2.5). One that already exists keeps its own. Coroutine.
func ensure_character(world_id: int, display_name: String, realm: StringName,
		starter_template: StringName = &"") -> ApiResult:
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
	var template_id: StringName = starter_template
	if template_id.is_empty() or not ClientConfig.is_selectable_template(String(template_id)):
		template_id = first_starter_template()
	var created: ApiResult = await create_character(world_id, display_name, realm_id, race_id_for(realm_id),
			default_appearance(realm_id), template_id)
	if not created.ok:
		return created
	return ApiResult.success({"character": created.data.get("character", {}), "created": true}, created.status)


## Asks to enter the world with [param character_id] and returns in [code]data.config[/code] the
## [OnlineMain] configuration (a copy of [param base] with the ticket). Retries [code]character_busy[/code] (§5.3). Coroutine.
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


## Stops retrying the entry of [method enter] (the response it awaits is the last one received).
func cancel_enter() -> void:
	_cancel_enter = true


## The [OnlineMain] configuration from the response of [code]enter[/code] ([param data], §4.5): a copy of
## [param base] with the zone's address and port, the ticket, the character (id, name and realm) and the
## DTLS certificate (or none), without an equipment template ([member ClientConfig.loadout]: the platform decides the kit). A mode without a network becomes
## [constant ClientConfig.Mode.ONLINE]. Null if the response is not understood.
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


## The bytes of a standard base64 text (empty if it is not; without logging engine errors).
static func decode_base64(text: Variant) -> PackedByteArray:
	if not text is String:
		return PackedByteArray()
	if _base64 == null:
		_base64 = RegEx.create_from_string(_BASE64_PATTERN)
	var clean: String = (text as String).strip_edges()
	if clean.is_empty() or clean.length() % 4 != 0 or _base64.search(clean) == null:
		return PackedByteArray()
	return Marshalls.base64_to_raw(clean)


## An API id (§4.1: a decimal string with no sign or leading zeros) as an integer; 0 if it is not.
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


## The people of [param realm_id] (id from [RealmCatalog]) in the appearance catalog; [code]race_<realm>[/code] if
## the catalog does not have it.
static func race_id_for(realm_id: StringName) -> StringName:
	var race: RaceDefinition = AppearanceCatalog.shared().race_for_realm(realm_id)
	return race.id if race != null else StringName("race_%s" % realm_id)


## The 8 B of the default appearance of the people of [param realm_id] (8 zeros if there is no people).
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


## The starter templates that can be chosen on creation (the [EquipmentTemplate]s with
## [member EquipmentTemplate.selectable], the [code]starter_templates[/code] section of the exported rules), by id.
static func starter_templates() -> Array[EquipmentTemplate]:
	var result: Array[EquipmentTemplate] = []
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if template != null and template.selectable:
			result.append(template)
	result.sort_custom(func(a: EquipmentTemplate, b: EquipmentTemplate) -> bool: return String(a.id) < String(b.id))
	return result


## The first starter template by id (the bot's and the one marked on creation); [code]&""[/code] if there is none.
static func first_starter_template() -> StringName:
	var templates: Array[EquipmentTemplate] = starter_templates()
	return templates[0].id if not templates.is_empty() else &""
