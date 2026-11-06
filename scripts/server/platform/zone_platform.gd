class_name ZonePlatform
extends Node
## The zone facing the platform (docs/platform.md §5.3, §6, §8 and §14.3): registration and startup, heartbeat with its
## set of leases, fencing, clock, claims, releases, saves, id blocks,
## fortresses, batches and one-off requests. Everything goes through its [PlatformClient] (priority queues and retries).
## [br][br]
## Responses are stored on arrival and delivered as [PlatformEvent]s in the tick's "poll" step with
## [method take_events]; never mid-tick. Those of the release and the batches do not come out as events: they are
## retried until a final one and rejections are logged. Those of the registration, the fortress GET and the
## first block end in [signal startup_finished] (the first block also comes out as an
## [code]id_block[/code] event, for [code]ProgressService[/code]). An [code]instance_lost[/code],
## [code]instance_replaced[/code] or [code]instance_stopped[/code] in any response, or in its
## [code]instance_status[/code], gives a single [code]instance_closed[/code] event (§6.1).
## [br][br]
## [b]Startup[/b] ([method start], §8): (1) registration, which leaves the instance in [code]starting[/code]; with 409
## [code]instance_alive[/code] and without [code]--replace[/code], again every 2 s for 60 s; with 403, 409
## [code]schema_mismatch[/code] or 60 s without a response, error. (2) The [code]env[/code] against the development
## options (§5.5) and the test ticket key (only in [code]test[/code]). (3) GET of the zone's fortresses.
## (3b) The first id block. Heartbeats start after registration. Then [code]ServerMain[/code] opens
## the port and calls [method go_live].
## [br][br]
## [b]Secrets[/b] ([method read_secrets]): the zone token and the ticket keys, from
## [code]ELDMARK_ZONE_TOKEN[/code] and [code]ELDMARK_TICKET_KEYS[/code] or from the files of their
## [code]*_FILE[/code] variables; never from the command line, which is visible with [code]ps[/code] (§10.3).

## After the registration, the fortresses and the first block ([param ok]); or the reason the zone cannot
## start.
signal startup_finished(ok: bool, error: String)
## [code]live[/code] exhausted its retries: the zone exits (§6).
signal fatal_error(error: String)

## [code]record_format[/code] of the record (§7.1): [code]ProgressRecord.FORMAT[/code] has the same value
## (progression.md §3.4, checked by its P5a).
const RECORD_FORMAT: int = 1
## Platform environments.
const ENV_DEV: StringName = &"dev"
const ENV_TEST: StringName = &"test"
const ENV_STAGING: StringName = &"staging"
const ENV_PRODUCTION: StringName = &"production"
## Clock offset above which a warning is issued (s).
const CLOCK_WARNING_S: int = 2
## Wait between registrations with 409 instance_alive (s) and cap for the whole startup (s).
const ALIVE_RETRY_S: float = 2.0
const STARTUP_LIMIT_S: float = 60.0
## Batches: how often they go out (s), how many entries and how many bytes at most, and how many queued before
## dropping the oldest chat.
const BATCH_INTERVAL_S: float = 2.0
const BATCH_MAX_ENTRIES: int = 200
const BATCH_MAX_BYTES: int = 1000000
const MAX_QUEUED_BATCH_ENTRIES: int = 20000
## Routes and field of each batch class.
const BATCH_ROUTES: Dictionary[StringName, Array] = {
	&"chat": ["/internal/v1/chat", "messages"],
	&"audit": ["/internal/v1/audit", "entries"],
	&"war": ["/internal/v1/war-events", "events"],
}
## Own request classes (those that do not come out as events).
const KIND_REGISTER: StringName = &"register"
const KIND_LIVE: StringName = &"live"
const KIND_FORTRESSES: StringName = &"fortresses"
const KIND_RELEASE: StringName = &"release"
const KIND_STOP: StringName = &"stop"
## The key of the platform.md §5.1 vector (00 01 … 1f): only valid in [code]test[/code].
const TEST_TICKET_KEY_HEX: String = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
## Minimum size of a ticket key.
const MIN_TICKET_KEY_BYTES: int = 32

## Deadline of each attempt (s); applied to the client in [method start].
var timeout_s: float = 3.0
## Cap on each startup step and on [code]live[/code] (s): [constant STARTUP_LIMIT_S]; tests lower it.
var startup_limit_s: float = STARTUP_LIMIT_S
## Players for the heartbeat: an argument-less [Callable] that returns an int ([method ZoneServer.get_player_count]).
var player_count_source: Callable = Callable()
## The zone's log (a [Callable] with a text); without it, print.
var log_sink: Callable = Callable()

var _client: PlatformClient = null
var _config: ServerConfig = null
var _secrets: Dictionary = {}
var _instance_id: String = ""
var _env: StringName = &""
var _heartbeat_s: float = 5.0
var _lease_ttl_s: int = 30
var _clock_offset_s: int = 0
var _registered: bool = false
var _live: bool = false
var _startup_done: bool = false
var _startup_deadline_msec: int = 0
var _last_accepted_heartbeat_msec: int = -1
var _heartbeat_in_flight: bool = false
var _next_heartbeat_msec: int = 0
## The heartbeat's set: character_id -> lease_id (§5.3).
var _heartbeat_set: Dictionary[int, String] = {}
var _claimed: Dictionary[int, ClaimedCharacter] = {}
var _events: Array[PlatformEvent] = []
var _closed: bool = false
var _flushing: bool = false
var _stopped: bool = false
var _fortress_records: Array[Dictionary] = []
var _fortress_versions: Dictionary[StringName, int] = {}
var _fortress_latest: Dictionary[StringName, Dictionary] = {}
var _fortress_in_flight: Dictionary[StringName, bool] = {}
var _batch_queues: Dictionary[StringName, Array] = {}
var _batch_in_flight: Dictionary[StringName, bool] = {}
var _batch_next_msec: Dictionary[StringName, int] = {}
var _batch_seq: int = 0
var _dropped_chat: int = 0


func _init() -> void:
	for kind: StringName in BATCH_ROUTES:
		_batch_queues[kind] = []
		_batch_in_flight[kind] = false
		_batch_next_msec[kind] = 0


func _process(_delta: float) -> void:
	if _stopped or not _registered:
		return
	var now: int = Time.get_ticks_msec()
	if not _heartbeat_in_flight and now >= _next_heartbeat_msec:
		_send_heartbeat(now)
	_pump_batches(now)


# --- Secrets ----------------------------------------------------------------------------------

## Reads the zone's secrets from the environment: [code]{token: String, ticket_keys: Dictionary[int,
## PackedByteArray], errors: PackedStringArray}[/code]. Each one accepts [code]<NAME>_FILE[/code] with the path to
## a file; both at once is an error, and so is a missing one.
static func read_secrets() -> Dictionary:
	var errors := PackedStringArray()
	var token: String = _read_secret("ELDMARK_ZONE_TOKEN", errors)
	var keys_text: String = _read_secret("ELDMARK_TICKET_KEYS", errors)
	var keys: Dictionary[int, PackedByteArray] = {}
	if not keys_text.is_empty():
		var parsed: Dictionary = parse_ticket_keys(keys_text)
		errors.append_array(parsed["errors"])
		keys = parsed["keys"]
	return {"token": token, "ticket_keys": keys, "errors": errors}


## The ticket keys from [param text] ([code]1:<base64 of 32 B>,2:<…>[/code], like
## [code]ELDMARK_TICKET_KEYS[/code] on the platform): [code]{keys: Dictionary[int, PackedByteArray], errors:
## PackedStringArray}[/code]. An id outside 1–255, repeated, or a key shorter than 32 B are errors.
static func parse_ticket_keys(text: String) -> Dictionary:
	var keys: Dictionary[int, PackedByteArray] = {}
	var errors := PackedStringArray()
	for entry: String in text.strip_edges().split(",", false):
		var parts: PackedStringArray = entry.strip_edges().split(":", true, 1)
		if parts.size() != 2 or not parts[0].strip_edges().is_valid_int():
			errors.append("ELDMARK_TICKET_KEYS: una entrada no tiene la forma <id>:<base64>")
			continue
		var key_id: int = parts[0].strip_edges().to_int()
		if key_id < 1 or key_id > 255:
			errors.append("ELDMARK_TICKET_KEYS: el id %d no está entre 1 y 255" % key_id)
			continue
		if keys.has(key_id):
			errors.append("ELDMARK_TICKET_KEYS: el id %d está repetido" % key_id)
			continue
		var encoded: String = parts[1].strip_edges()
		var key: PackedByteArray = Marshalls.base64_to_raw(encoded) if _is_base64(encoded) else PackedByteArray()
		if key.size() < MIN_TICKET_KEY_BYTES:
			errors.append("ELDMARK_TICKET_KEYS: la clave %d no es base64 de %d B o más" % [key_id,
					MIN_TICKET_KEY_BYTES])
			continue
		keys[key_id] = key
	if keys.is_empty() and errors.is_empty():
		errors.append("ELDMARK_TICKET_KEYS: no hay ninguna clave")
	return {"keys": keys, "errors": errors}


static func _read_secret(name: String, errors: PackedStringArray) -> String:
	var direct: String = OS.get_environment(name).strip_edges()
	var file_path: String = OS.get_environment(name + "_FILE").strip_edges()
	if not direct.is_empty() and not file_path.is_empty():
		errors.append("%s y %s_FILE no pueden ir a la vez" % [name, name])
		return ""
	if not file_path.is_empty():
		if not FileAccess.file_exists(file_path):
			errors.append("%s_FILE: no existe %s" % [name, file_path])
			return ""
		direct = FileAccess.get_file_as_string(file_path).strip_edges()
	if direct.is_empty():
		errors.append("falta %s (o %s_FILE)" % [name, name])
	return direct


# true if [param text] only has standard base64 characters (Marshalls would log an error with others).
static func _is_base64(text: String) -> bool:
	if text.is_empty() or text.length() % 4 != 0:
		return false
	for i: int in text.length():
		var c: String = text[i]
		var ok: bool = (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") \
				or c == "+" or c == "/" or (c == "=" and i >= text.length() - 2)
		if not ok:
			return false
	return true


# --- Startup ----------------------------------------------------------------------------------

## Starts the startup of §8 against [member ServerConfig.platform_url] with [param secrets] (those from
## [method read_secrets]). The result arrives through [signal startup_finished]. It must be in the tree.
func start(config: ServerConfig, secrets: Dictionary) -> void:
	if _client != null:
		return
	_config = config
	_secrets = secrets
	_client = _make_client()
	_client.name = "PlatformClient"
	_client.base_url = config.platform_url.strip_edges().trim_suffix("/")
	_client.token = String(secrets.get("token", ""))
	_client.timeout_s = timeout_s
	add_child(_client)
	_startup_deadline_msec = Time.get_ticks_msec() + int(startup_limit_s * 1000.0)
	_register(0)


## The HTTP client; the tests' fake swaps it for one without a network.
func _make_client() -> PlatformClient:
	return PlatformClient.new()


## The registration body (§6) of [param config].
static func registration_body(config: ServerConfig) -> Dictionary:
	var realms: Array = []
	var allowed: PackedInt32Array = NetZones.allowed_realms(config.zone_id)
	if allowed.is_empty():
		for code: int in RealmCatalog.realm_codes():
			realms.append(code)
	else:
		for code: int in allowed:
			realms.append(code)
	return {
		"world_id": config.world_id, "zone_id": config.zone_id, "channel": config.channel,
		"public_host": config.public_host(), "public_port": config.public_port(), "realms": realms,
		"build_id": build_id(), "protocol_version": NetProtocol.PROTOCOL_VERSION,
		"record_format": RECORD_FORMAT, "max_players": config.max_players,
		# The zone's DTLS certificate and its CN (platform.md §10.2, P9c), which the platform gives to the client in enter;
		# without DTLS, null (in staging and production the platform does not register a zone without a certificate).
		"dtls_cert_pem": config.dtls.certificate_pem if config.dtls != null else null,
		"dtls_name": config.dtls.common_name if config.dtls != null else null,
		"replace": config.replace,
	}


## Zone version for the registration (see [BuildInfo]): the project's, the protocol's and the revision's.
static func build_id() -> String:
	return BuildInfo.build_id()


func _register(not_before_msec: int) -> void:
	var request := _request(HTTPClient.METHOD_POST, "/internal/v1/zone-instances", registration_body(_config),
			PlatformClient.PRIORITY_CONTROL, KIND_REGISTER, null, PlatformClient.Retry.STARTUP, _on_registered)
	request.deadline_msec = _startup_deadline_msec
	request.not_before_msec = not_before_msec
	_client.submit(request)


func _on_registered(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	if event.is_success():
		var body: Dictionary = event.body_dict()
		var instance: String = PlatformJson.text_in(body, "zone_instance_id")
		var env: StringName = StringName(PlatformJson.text_in(body, "env"))
		var heartbeat: Variant = body.get("heartbeat_s")
		if instance.is_empty() or not [ENV_DEV, ENV_TEST, ENV_STAGING, ENV_PRODUCTION].has(env) \
				or not (heartbeat is int or heartbeat is float) or float(heartbeat) <= 0.0:
			_fail_startup("La plataforma ha respondido al registro con un cuerpo que no se entiende")
			return
		_instance_id = instance
		_env = env
		_heartbeat_s = float(heartbeat)
		_lease_ttl_s = PlatformJson.int_in(body, "lease_ttl_s", 1, 86400, 30)
		_set_clock(body)
		_registered = true
		_last_accepted_heartbeat_msec = Time.get_ticks_msec()
		_next_heartbeat_msec = _last_accepted_heartbeat_msec + int(_heartbeat_s * 1000.0)
		_log("Registrada en la plataforma: instancia %s (env %s, latido cada %s s)" % [_instance_id, _env,
				_heartbeat_s])
		var guard: String = env_guard_error(_config, _env, _secrets)
		if not guard.is_empty():
			# The removal before the notice: whoever waits for startup_finished can exit right away, after draining the queue.
			deregister()
			_fail_startup(guard)
			return
		_load_fortresses()
		return
	var now: int = Time.get_ticks_msec()
	if event.status == 409 and event.error_code == "instance_alive" and not _config.replace \
			and now + int(ALIVE_RETRY_S * 1000.0) <= _startup_deadline_msec:
		_log("Hay otra instancia viva de %s:%d: se vuelve a registrar en %.0f s" % [_config.zone_id,
				_config.channel, ALIVE_RETRY_S])
		_register(now + int(ALIVE_RETRY_S * 1000.0))
		return
	_fail_startup("El registro en la plataforma ha fallado: %s" % describe(event))


## The reason the zone cannot start with [param env] (§5.5), or empty: development options
## are only valid in [code]dev[/code] and [code]test[/code], and the test ticket key only in [code]test[/code].
static func env_guard_error(config: ServerConfig, env: StringName, secrets: Dictionary) -> String:
	if env != ENV_DEV and env != ENV_TEST:
		var options: PackedStringArray = config.platform_dev_options()
		if not options.is_empty():
			return "Esa opción no se admite con la plataforma en staging/production: %s" % ", ".join(options)
	if env != ENV_TEST:
		var keys: Variant = secrets.get("ticket_keys", {})
		if keys is Dictionary:
			for key: Variant in (keys as Dictionary).values():
				if key is PackedByteArray and (key as PackedByteArray).hex_encode() == TEST_TICKET_KEY_HEX:
					return "La clave de prueba del billete solo vale con la plataforma en test"
	return ""


func _load_fortresses() -> void:
	# Each startup step gets its 60 s (§8).
	_startup_deadline_msec = Time.get_ticks_msec() + int(startup_limit_s * 1000.0)
	var request := _request(HTTPClient.METHOD_GET, "/internal/v1/fortresses?zone_instance_id=%s" % _instance_id,
			null, PlatformClient.PRIORITY_CONTROL, KIND_FORTRESSES, null, PlatformClient.Retry.STARTUP,
			_on_fortresses)
	request.deadline_msec = _startup_deadline_msec
	_client.submit(request)


func _on_fortresses(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	if not event.is_success():
		_fail_startup("No se han podido leer las fortalezas de la plataforma: %s" % describe(event))
		return
	var list: Array = PlatformJson.array_in(event.body_dict(), "fortresses")
	_fortress_records.clear()
	for value: Variant in list:
		if not value is Dictionary:
			continue
		var entry: Dictionary = value
		var fortress_id: String = PlatformJson.text_in(entry, "fortress_id")
		if fortress_id.is_empty() or not entry.get("record") is Dictionary:
			continue
		var version: int = PlatformJson.int_in(entry, "version", 0, PlatformJson.MAX_SAFE_INT, 0)
		_fortress_versions[StringName(fortress_id)] = version
		_fortress_records.append({"fortress_id": StringName(fortress_id), "record": entry["record"],
				"version": version})
	_startup_deadline_msec = Time.get_ticks_msec() + int(startup_limit_s * 1000.0)
	var request := _request(HTTPClient.METHOD_POST, "/internal/v1/id-blocks", {"zone_instance_id": _instance_id},
			PlatformClient.PRIORITY_CONTROL,
			PlatformEvent.KIND_ID_BLOCK, null, PlatformClient.Retry.STARTUP, _on_first_block)
	request.deadline_msec = _startup_deadline_msec
	_client.submit(request)


func _on_first_block(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	if not event.is_success():
		_fail_startup("No se ha podido pedir el primer bloque de ids: %s" % describe(event))
		return
	_events.append(event)
	_startup_done = true
	startup_finished.emit(true, "")


func _fail_startup(error: String) -> void:
	if _startup_done:
		return
	_startup_done = true
	_log(error)
	startup_finished.emit(false, error)


## POST …/live after opening the port: from here on [code]enter[/code] sends players. It is retried for 60 s; if
## exhausted, [signal fatal_error].
func go_live() -> void:
	if not _registered or _live:
		return
	var request := _request(HTTPClient.METHOD_POST, "/internal/v1/zone-instances/%s/live" % _instance_id, null,
			PlatformClient.PRIORITY_CONTROL, KIND_LIVE, null, PlatformClient.Retry.STARTUP, _on_live)
	request.deadline_msec = Time.get_ticks_msec() + int(startup_limit_s * 1000.0)
	_client.submit(request)


func _on_live(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	if event.is_success():
		_live = true
		_log("La instancia %s está viva: la plataforma ya manda jugadores" % _instance_id)
		return
	var error: String = "La plataforma no ha dado la zona por viva: %s" % describe(event)
	_log(error)
	fatal_error.emit(error)


## Instance removal (DELETE, §6): [code]stopped[/code] and the platform releases whatever remains. Heartbeats
## stop.
func deregister() -> void:
	if not _registered or _stopped:
		return
	_stopped = true
	_client.submit(_request(HTTPClient.METHOD_DELETE, "/internal/v1/zone-instances/%s" % _instance_id, null,
			PlatformClient.PRIORITY_CONTROL, KIND_STOP, null, PlatformClient.Retry.NONE, _on_logged))


# --- Queries ----------------------------------------------------------------------------------

## The fortresses loaded at startup: [code]{fortress_id: StringName, record: Dictionary, version:
## int}[/code] (applied by [code]FortressPersistence[/code], P6).
func fortress_records() -> Array[Dictionary]:
	return _fortress_records


## The registration's [code]env[/code] (&"dev", &"test", &"staging" or &"production"); empty before registration.
func env() -> StringName:
	return _env


## The [code]zone_instance_id[/code]; empty before registration.
func instance_id() -> String:
	return _instance_id


## true after the 204 of [method go_live].
func is_live() -> bool:
	return _live


## true without an accepted heartbeat in 2 × [code]heartbeat_s[/code] (and before registration): the zone does not accept HELLO
## (REJECT UNAVAILABLE) or operations that require a critical save. It expels nobody (§5.3).
func is_fenced() -> bool:
	if not _registered:
		return true
	return Time.get_ticks_msec() - _last_accepted_heartbeat_msec > int(2.0 * _heartbeat_s * 1000.0)


## The Unix time (s) with the platform's clock: the system's plus the offset from the last registration or heartbeat.
func now_unix() -> int:
	return int(Time.get_unix_time_from_system()) + _clock_offset_s


## Seconds between heartbeats (those from the registration).
func heartbeat_interval_s() -> float:
	return _heartbeat_s


## The heartbeat's set right now: character_id -> lease_id.
func heartbeat_set() -> Dictionary[int, String]:
	return _heartbeat_set.duplicate()


## The latest claim (200) of character [param character_id], or null.
func claimed(character_id: int) -> ClaimedCharacter:
	return _claimed.get(character_id)


## The HTTP client (null before [method start]); for metrics and tests.
func get_client() -> PlatformClient:
	return _client


# --- Requests ---------------------------------------------------------------------------------

## Requests the claim of [param peer_id]'s ticket (priority 1, no retry: cut short by the deadline of §5.2).
## The response is a [code]claim[/code] event with [code]context = {peer_id, character_id, ticket_id}[/code]. With
## the 200, the character enters the heartbeat set.
func claim(peer_id: int, ticket: HandoffTicket) -> void:
	var body: Dictionary = {
		"zone_instance_id": _instance_id, "ticket_id": PlatformJson.id_text(ticket.ticket_id),
		"character_id": PlatformJson.id_text(ticket.character_id),
	}
	var context: Dictionary = {"peer_id": peer_id, "character_id": ticket.character_id,
			"ticket_id": ticket.ticket_id}
	_client.submit(_request(HTTPClient.METHOD_POST, "/internal/v1/claims", body, PlatformClient.PRIORITY_ENTRY,
			PlatformEvent.KIND_CLAIM, context, PlatformClient.Retry.NONE, _on_claim))


func _on_claim(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	if event.is_success():
		var context: Dictionary = event.context
		var claimed_character: ClaimedCharacter = ClaimedCharacter.from_claim(event.body_dict())
		if claimed_character != null and claimed_character.character_id == int(context["character_id"]):
			_claimed[claimed_character.character_id] = claimed_character
			_heartbeat_set[claimed_character.character_id] = claimed_character.lease_id
	_events.append(event)


## Releases without saving lease [param lease_id] of [param character_id] (priority 1; retried like
## a save until a final response, and a 4xx is one). It leaves the heartbeat set if it is still that
## [param lease_id].
func release(character_id: int, lease_id: String) -> void:
	_forget_lease(character_id, lease_id)
	var body: Dictionary = {"zone_instance_id": _instance_id, "lease_id": lease_id}
	_client.submit(_request(HTTPClient.METHOD_POST, "/internal/v1/characters/%d/release" % character_id, body,
			PlatformClient.PRIORITY_ENTRY, KIND_RELEASE, {"character_id": character_id, "lease_id": lease_id},
			PlatformClient.Retry.STEADY, _on_logged))


## Sends the save [param body] (the whole envelope from [code]CharacterSaver[/code], §7.3) without touching its bytes,
## with the same body on each retry until a final response, which comes out as a [code]save[/code] event
## with [param context]. With [param release_lease], that response removes the character from the heartbeat set if
## it is still that [param lease_id].
func save(character_id: int, lease_id: String, body: PackedByteArray, release_lease: bool,
		context: Variant) -> void:
	var request := PlatformClient.Request.new()
	request.method = HTTPClient.METHOD_PUT
	request.path = "/internal/v1/characters/%d/state" % character_id
	request.body = body
	request.priority = PlatformClient.PRIORITY_PLAYER
	request.kind = PlatformEvent.KIND_SAVE
	request.context = context
	request.retry = PlatformClient.Retry.STEADY
	request.on_done = func(_r: PlatformClient.Request, event: PlatformEvent) -> void:
		_check_closing(event)
		if release_lease:
			_forget_lease(character_id, lease_id)
		_events.append(event)
	_client.submit(request)


## Requests an id block (priority 2, with retries): [code]id_block[/code] event with
## [code]{first, count}[/code] for [code]ProgressService[/code].
func request_id_block() -> void:
	_client.submit(_request(HTTPClient.METHOD_POST, "/internal/v1/id-blocks", {"zone_instance_id": _instance_id},
			PlatformClient.PRIORITY_PLAYER, PlatformEvent.KIND_ID_BLOCK, null, PlatformClient.Retry.STEADY, _on_event))


## Saves a fortress's record (priority 3): one request in flight per fortress, always with the most
## recent record and with [code]expected_version[/code]; with 409 [code]version_conflict[/code] it takes the
## version from the error and resends it (§8). Each response comes out as a [code]fortress[/code] event.
func put_fortress(fortress_id: StringName, record: Dictionary) -> void:
	_fortress_latest[fortress_id] = record.duplicate(true)
	if not _fortress_in_flight.get(fortress_id, false):
		_send_fortress(fortress_id)


func _send_fortress(fortress_id: StringName) -> void:
	var record: Dictionary = _fortress_latest[fortress_id]
	_fortress_latest.erase(fortress_id)
	_fortress_in_flight[fortress_id] = true
	var body: Dictionary = {"zone_instance_id": _instance_id,
			"expected_version": _fortress_versions.get(fortress_id, 0), "record": record}
	_client.submit(_request(HTTPClient.METHOD_PUT, "/internal/v1/fortresses/%s" % String(fortress_id).uri_encode(),
			body, PlatformClient.PRIORITY_FORTRESS, PlatformEvent.KIND_FORTRESS,
			{"fortress_id": fortress_id, "record": record}, PlatformClient.Retry.FORTRESS, _on_fortress))


func _on_fortress(request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	var fortress_id: StringName = (request.context as Dictionary)["fortress_id"]
	_fortress_in_flight[fortress_id] = false
	if event.is_success():
		_fortress_versions[fortress_id] = PlatformJson.int_in(event.body_dict(), "version", 0,
				PlatformJson.MAX_SAFE_INT, _fortress_versions.get(fortress_id, 0))
	elif event.status == 409 and event.error_code == "version_conflict":
		var error: Dictionary = event.error_dict()
		var version: int = PlatformJson.int_in(error, "version", 0, PlatformJson.MAX_SAFE_INT,
				PlatformJson.int_in(event.body_dict(), "version", 0, PlatformJson.MAX_SAFE_INT, 0))
		_fortress_versions[fortress_id] = version
		# The live instance rules: its record is resent (the most recent one if there is a new one).
		if not _fortress_latest.has(fortress_id):
			_fortress_latest[fortress_id] = (request.context as Dictionary)["record"]
	_events.append(event)
	if _fortress_latest.has(fortress_id) and not _closed:
		_send_fortress(fortress_id)


## Queues a batch entry ([code]&"chat"[/code], [code]&"audit"[/code] or [code]&"war"[/code]). If it
## carries no [code]key[/code], [code]"<zone_instance_id>:<n>"[/code] is set; one that carries it
## ([code]op:<op_id>[/code]) keeps it. Batches go out every 2 s or with 200 entries.
func enqueue_batch(kind: StringName, entry: Dictionary) -> void:
	if not _batch_queues.has(kind):
		_log("Lote desconocido: %s" % kind)
		return
	var copy: Dictionary = entry.duplicate(true)
	if not copy.has("key"):
		_batch_seq += 1
		copy["key"] = "%s:%d" % [_instance_id, _batch_seq]
	var queue: Array = _batch_queues[kind]
	queue.append(copy)
	_trim_batches()


## A one-off request of [param kind] ([code]&"progress_op"[/code], [code]&"progress_ledger"[/code],
## [code]&"ignore"[/code], [code]&"report"[/code] or [code]&"sanction"[/code]), without retry. Sets
## [code]zone_instance_id[/code] in the query of a GET and in the body of the others. The response is an event of
## [param kind] with [param context].
func request(kind: StringName, method: HTTPClient.Method, path: String, body: Dictionary, priority: int,
		context: Variant) -> void:
	var full_path: String = path
	var payload: Variant = null
	if method == HTTPClient.METHOD_GET:
		full_path += ("&" if path.contains("?") else "?") + "zone_instance_id=" + _instance_id
	else:
		var copy: Dictionary = body.duplicate(true)
		copy["zone_instance_id"] = _instance_id
		payload = copy
	_client.submit(_request(method, full_path, payload, priority, kind, context, PlatformClient.Retry.NONE,
			_on_event))


## The events that arrived since the last call, in arrival order. In the tick's "poll" step.
func take_events() -> Array[PlatformEvent]:
	var taken: Array[PlatformEvent] = _events
	_events = []
	return taken


## Shutdown: batches and whatever waits for its retry go out now.
func begin_flush() -> void:
	_flushing = true
	if _client != null:
		_client.hurry()
	_pump_batches(Time.get_ticks_msec())


## true if nothing remains queued or in flight (not counting heartbeats).
func is_flushed() -> bool:
	if _client != null and _client.pending_count(PlatformEvent.KIND_HEARTBEAT) > 0:
		return false
	for kind: StringName in _batch_queues:
		if not (_batch_queues[kind] as Array).is_empty() or _batch_in_flight[kind]:
			return false
	return _fortress_latest.is_empty()


## Sends a heartbeat now if none is in flight (tests and tools).
func send_heartbeat_now() -> void:
	if _registered and not _stopped and not _heartbeat_in_flight:
		_send_heartbeat(Time.get_ticks_msec())


## The text of a failure for the log: the HTTP code and the error's, or "sin respuesta" (no response).
static func describe(event: PlatformEvent) -> String:
	if not event.transport_ok:
		return "sin respuesta de la plataforma"
	if event.error_code.is_empty():
		return "HTTP %d" % event.status
	return "HTTP %d %s" % [event.status, event.error_code]


# --- Heartbeat and batches --------------------------------------------------------------------

func _send_heartbeat(now: int) -> void:
	_heartbeat_in_flight = true
	_next_heartbeat_msec = now + int(_heartbeat_s * 1000.0)
	var characters: Array = []
	var ids: Array[int] = _heartbeat_set.keys()
	ids.sort()
	for character_id: int in ids:
		characters.append({"character_id": PlatformJson.id_text(character_id),
				"lease_id": _heartbeat_set[character_id]})
	var players: int = int(player_count_source.call()) if player_count_source.is_valid() else 0
	# The context says for whom and when the heartbeat was sent: the response's mutes only apply to those characters and
	# do not undo a later sanction by the zone (platform.md §9.5, P7b).
	var context: Dictionary = {"characters": _heartbeat_set.duplicate(), "sent_msec": now}
	_client.submit(_request(HTTPClient.METHOD_POST, "/internal/v1/zone-instances/%s/heartbeat" % _instance_id,
			{"players": players, "characters": characters}, PlatformClient.PRIORITY_CONTROL,
			PlatformEvent.KIND_HEARTBEAT, context, PlatformClient.Retry.NONE, _on_heartbeat))


func _on_heartbeat(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	_heartbeat_in_flight = false
	_check_closing(event)
	if not event.is_success():
		if event.transport_ok and event.status != 409:
			_log("Latido rechazado: %s" % describe(event))
		return
	_last_accepted_heartbeat_msec = Time.get_ticks_msec()
	var body: Dictionary = event.body_dict()
	_set_clock(body)
	# A lease_lost no longer belongs to this zone: it stops heartbeating for it.
	for value: Variant in PlatformJson.array_in(body, "revoked"):
		var revoked: Dictionary = value if value is Dictionary else {}
		if PlatformJson.text_in(revoked, "reason") == "lease_lost":
			_forget_lease(PlatformJson.id_of(revoked.get("character_id")), PlatformJson.text_in(revoked, "lease_id"))
	_events.append(event)


func _pump_batches(now: int) -> void:
	for kind: StringName in _batch_queues:
		var queue: Array = _batch_queues[kind]
		if queue.is_empty() or _batch_in_flight[kind]:
			continue
		if not _flushing and queue.size() < BATCH_MAX_ENTRIES and now < _batch_next_msec[kind]:
			continue
		_send_batch(kind, queue)
		_batch_next_msec[kind] = now + int(BATCH_INTERVAL_S * 1000.0)


func _send_batch(kind: StringName, queue: Array) -> void:
	var route: Array = BATCH_ROUTES[kind]
	var entries: Array = []
	var size: int = 64
	while not queue.is_empty() and entries.size() < BATCH_MAX_ENTRIES:
		var entry_size: int = JSON.stringify(queue[0]).length() + 1
		if not entries.is_empty() and size + entry_size > BATCH_MAX_BYTES:
			break
		entries.append(queue.pop_front())
		size += entry_size
	_batch_in_flight[kind] = true
	var body: Dictionary = {"zone_instance_id": _instance_id, String(route[1]): entries}
	_client.submit(_request(HTTPClient.METHOD_POST, String(route[0]), body, PlatformClient.PRIORITY_BATCH, kind,
			{"count": entries.size()}, PlatformClient.Retry.BATCH, _on_batch))


func _on_batch(request: PlatformClient.Request, event: PlatformEvent) -> void:
	_batch_in_flight[request.kind] = false
	_check_closing(event)
	if event.status == 200:
		var rejected: Array = PlatformJson.array_in(event.body_dict(), "rejected")
		if not rejected.is_empty():
			_log("Lote de %s: la plataforma rechaza %d entradas (%s)" % [request.kind, rejected.size(),
					JSON.stringify(rejected).left(300)])
	elif not event.is_success():
		_log("Lote de %s descartado: %s" % [request.kind, describe(event)])
	_pump_batches(Time.get_ticks_msec())


# With more than MAX_QUEUED_BATCH_ENTRIES entries queued, the oldest chat is dropped (with a warning); audit
# and war never are (§6).
func _trim_batches() -> void:
	var total: int = 0
	for kind: StringName in _batch_queues:
		total += (_batch_queues[kind] as Array).size()
	var chat: Array = _batch_queues[&"chat"]
	var dropped: int = 0
	while total > MAX_QUEUED_BATCH_ENTRIES and not chat.is_empty():
		chat.pop_front()
		total -= 1
		dropped += 1
	if dropped > 0:
		_dropped_chat += dropped
		if _dropped_chat == dropped or _dropped_chat % 1000 < dropped:
			_log("Cola de lotes llena: %d mensajes de chat descartados en total" % _dropped_chat)


# --- Helpers ----------------------------------------------------------------------------------

func _request(method: HTTPClient.Method, path: String, body: Variant, priority: int, kind: StringName,
		context: Variant, retry: int, on_done: Callable) -> PlatformClient.Request:
	var request := PlatformClient.Request.new()
	request.method = method
	request.path = path
	request.body = JSON.stringify(body).to_utf8_buffer() if body != null else PackedByteArray()
	request.priority = priority
	request.kind = kind
	request.context = context
	request.retry = retry
	request.on_done = on_done
	return request


func _on_event(_request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	_events.append(event)


func _on_logged(request: PlatformClient.Request, event: PlatformEvent) -> void:
	_check_closing(event)
	if not event.is_success():
		_log("%s rechazada: %s" % [request.kind, describe(event)])


# Removes [param character_id] from the heartbeat set if it still has [param lease_id].
func _forget_lease(character_id: int, lease_id: String) -> void:
	if _heartbeat_set.get(character_id, "") == lease_id:
		_heartbeat_set.erase(character_id)


# instance_lost, instance_replaced or instance_stopped (in the error or in instance_status): a single
# instance_closed. An instance_not_live is only logged.
func _check_closing(event: PlatformEvent) -> void:
	var code: String = ""
	if PlatformEvent.CLOSING_CODES.has(event.error_code):
		code = event.error_code
	elif event.is_success():
		var status: String = PlatformJson.text_in(event.body_dict(), "instance_status")
		if ["lost", "replaced", "stopped"].has(status):
			code = "instance_" + status
	elif event.error_code == "instance_not_live":
		_log("La plataforma responde instance_not_live a %s: la instancia aún no está viva" % event.kind)
	if code.is_empty() or _closed:
		return
	_closed = true
	_log("La plataforma cierra esta instancia: %s" % code)
	var closed := PlatformEvent.new()
	closed.kind = PlatformEvent.KIND_INSTANCE_CLOSED
	closed.transport_ok = true
	closed.status = event.status
	closed.body = {"code": code}
	closed.error_code = code
	_events.append(closed)


func _set_clock(body: Dictionary) -> void:
	if not PlatformJson.is_int(body.get("now_unix"), 1, PlatformJson.MAX_SAFE_INT):
		return
	var offset: int = int(body["now_unix"]) - int(Time.get_unix_time_from_system())
	if absi(offset) > CLOCK_WARNING_S and absi(offset - _clock_offset_s) > 0 \
			and absi(_clock_offset_s) <= CLOCK_WARNING_S:
		_log("El reloj de la zona va %d s desfasado respecto al de la plataforma" % offset)
	_clock_offset_s = offset


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] Plataforma: %s" % text)
