class_name ZonePlatform
extends Node
## La zona frente a la plataforma (docs/plataforma.md §5.3, §6, §8 y §14.3): registro y arranque, latido con su
## conjunto de arrendamientos, cercado, reloj, reclamaciones, liberaciones, guardados, bloques de ids,
## fortalezas, lotes y peticiones sueltas. Todo pasa por su [PlatformClient] (colas por prioridad y reintentos).
## [br][br]
## Las respuestas se guardan al llegar y se entregan como [PlatformEvent] en el paso «poll» del tick con
## [method take_events]; nunca a mitad de tick. Las de la liberación y de los lotes no salen como evento: se
## reintentan hasta una definitiva y se registran los rechazos. Las del registro, del GET de fortalezas y del
## primer bloque acaban en [signal startup_finished] (el primer bloque sale además como evento
## [code]id_block[/code], para [code]ProgressService[/code]). Un [code]instance_lost[/code],
## [code]instance_replaced[/code] o [code]instance_stopped[/code] en cualquier respuesta, o en su
## [code]instance_status[/code], da un solo evento [code]instance_closed[/code] (§6.1).
## [br][br]
## [b]Arranque[/b] ([method start], §8): (1) registro, que deja la instancia en [code]starting[/code]; con 409
## [code]instance_alive[/code] y sin [code]--replace[/code], otra vez cada 2 s durante 60 s; con 403, 409
## [code]schema_mismatch[/code] o 60 s sin respuesta, error. (2) El [code]env[/code] frente a las opciones de
## desarrollo (§5.5) y la clave de prueba del billete (solo en [code]test[/code]). (3) GET de las fortalezas de la
## zona. (3b) El primer bloque de ids. Los latidos empiezan tras el registro. Después [code]ServerMain[/code] abre
## el puerto y llama a [method go_live].
## [br][br]
## [b]Secretos[/b] ([method read_secrets]): el token de la zona y las claves del billete, de
## [code]ELDMARK_ZONE_TOKEN[/code] y [code]ELDMARK_TICKET_KEYS[/code] o de los archivos de sus variables
## [code]*_FILE[/code]; nunca de la línea de órdenes, que se ve con [code]ps[/code] (§10.3).

## Tras el registro, las fortalezas y el primer bloque ([param ok]); o el motivo por el que la zona no puede
## arrancar.
signal startup_finished(ok: bool, error: String)
## [code]live[/code] agotó sus reintentos: la zona sale (§6).
signal fatal_error(error: String)

## [code]record_format[/code] del registro (§7.1): [code]ProgressRecord.FORMAT[/code] vale lo mismo
## (progresion.md §3.4, lo comprueba su P5a).
const RECORD_FORMAT: int = 1
## Entornos de la plataforma.
const ENV_DEV: StringName = &"dev"
const ENV_TEST: StringName = &"test"
const ENV_STAGING: StringName = &"staging"
const ENV_PRODUCTION: StringName = &"production"
## Desfase del reloj a partir del cual se avisa (s).
const CLOCK_WARNING_S: int = 2
## Espera entre registros con 409 instance_alive (s) y tope de todo el arranque (s).
const ALIVE_RETRY_S: float = 2.0
const STARTUP_LIMIT_S: float = 60.0
## Lotes: cada cuánto salen (s), cuántas entradas y cuántos bytes como mucho, y cuántas en cola antes de
## descartar el chat más viejo.
const BATCH_INTERVAL_S: float = 2.0
const BATCH_MAX_ENTRIES: int = 200
const BATCH_MAX_BYTES: int = 1000000
const MAX_QUEUED_BATCH_ENTRIES: int = 20000
## Rutas y campo de cada clase de lote.
const BATCH_ROUTES: Dictionary[StringName, Array] = {
	&"chat": ["/internal/v1/chat", "messages"],
	&"audit": ["/internal/v1/audit", "entries"],
	&"war": ["/internal/v1/war-events", "events"],
}
## Clases de petición propias (las que no salen como evento).
const KIND_REGISTER: StringName = &"register"
const KIND_LIVE: StringName = &"live"
const KIND_FORTRESSES: StringName = &"fortresses"
const KIND_RELEASE: StringName = &"release"
const KIND_STOP: StringName = &"stop"
## La clave del vector de plataforma.md §5.1 (00 01 … 1f): solo vale en [code]test[/code].
const TEST_TICKET_KEY_HEX: String = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
## Tamaño mínimo de una clave del billete.
const MIN_TICKET_KEY_BYTES: int = 32

## Plazo de cada intento (s); se aplica al cliente en [method start].
var timeout_s: float = 3.0
## Tope de cada paso del arranque y de [code]live[/code] (s): [constant STARTUP_LIMIT_S]; las pruebas lo bajan.
var startup_limit_s: float = STARTUP_LIMIT_S
## Jugadores para el latido: un [Callable] sin argumentos que devuelve un int ([method ZoneServer.get_player_count]).
var player_count_source: Callable = Callable()
## Registro de la zona (un [Callable] con un texto); sin él, print.
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
## Conjunto del latido: character_id -> lease_id (§5.3).
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


# --- Secretos ---------------------------------------------------------------------------------

## Lee los secretos de la zona del entorno: [code]{token: String, ticket_keys: Dictionary[int,
## PackedByteArray], errors: PackedStringArray}[/code]. Cada uno admite [code]<NOMBRE>_FILE[/code] con la ruta de
## un archivo; los dos a la vez son un error, y uno que falta también.
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


## Las claves del billete de [param text] ([code]1:<base64 de 32 B>,2:<…>[/code], como
## [code]ELDMARK_TICKET_KEYS[/code] en la plataforma): [code]{keys: Dictionary[int, PackedByteArray], errors:
## PackedStringArray}[/code]. Un id fuera de 1–255, repetido, o una clave de menos de 32 B son errores.
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


# true si [param text] solo tiene caracteres de base64 estándar (Marshalls registraría un error con otros).
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


# --- Arranque ---------------------------------------------------------------------------------

## Empieza el arranque de §8 contra [member ServerConfig.platform_url] con [param secrets] (los de
## [method read_secrets]). El resultado llega por [signal startup_finished]. Tiene que estar en el árbol.
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


## El cliente HTTP; el falso de las pruebas lo cambia por uno sin red.
func _make_client() -> PlatformClient:
	return PlatformClient.new()


## El cuerpo del registro (§6) de [param config].
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
		# El certificado DTLS y su nombre los manda P9c (plataforma.md §10.2); sin ellos, null.
		"dtls_cert_pem": null, "dtls_name": null, "replace": config.replace,
	}


## Versión de la zona para el registro: la del proyecto y la del protocolo.
static func build_id() -> String:
	var version: String = str(ProjectSettings.get_setting("application/config/version", "0"))
	return ("eldmark-%s-p%d" % [version, NetProtocol.PROTOCOL_VERSION]).replace(" ", "_").left(64)


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
			# La baja antes del aviso: quien espera startup_finished puede salir enseguida, tras vaciar la cola.
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


## El motivo por el que la zona no puede arrancar con [param env] (§5.5), o vacío: las opciones de desarrollo
## solo valen en [code]dev[/code] y [code]test[/code], y la clave de prueba del billete, solo en [code]test[/code].
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
	# Cada paso del arranque tiene sus 60 s (§8).
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


## POST …/live tras abrir el puerto: desde aquí [code]enter[/code] manda jugadores. Se reintenta 60 s; si se
## agota, [signal fatal_error].
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


## Baja de la instancia (DELETE, §6): [code]stopped[/code] y la plataforma libera lo que quede. Los latidos
## paran.
func deregister() -> void:
	if not _registered or _stopped:
		return
	_stopped = true
	_client.submit(_request(HTTPClient.METHOD_DELETE, "/internal/v1/zone-instances/%s" % _instance_id, null,
			PlatformClient.PRIORITY_CONTROL, KIND_STOP, null, PlatformClient.Retry.NONE, _on_logged))


# --- Consultas --------------------------------------------------------------------------------

## Las fortalezas cargadas en el arranque: [code]{fortress_id: StringName, record: Dictionary, version:
## int}[/code] (las aplica [code]FortressPersistence[/code], P6).
func fortress_records() -> Array[Dictionary]:
	return _fortress_records


## El [code]env[/code] del registro (&"dev", &"test", &"staging" o &"production"); vacío antes del registro.
func env() -> StringName:
	return _env


## El [code]zone_instance_id[/code]; vacío antes del registro.
func instance_id() -> String:
	return _instance_id


## true tras el 204 de [method go_live].
func is_live() -> bool:
	return _live


## true sin un latido aceptado en 2 × [code]heartbeat_s[/code] (y antes del registro): la zona no admite HELLO
## (REJECT UNAVAILABLE) ni operaciones que piden guardado crítico. No expulsa a nadie (§5.3).
func is_fenced() -> bool:
	if not _registered:
		return true
	return Time.get_ticks_msec() - _last_accepted_heartbeat_msec > int(2.0 * _heartbeat_s * 1000.0)


## La hora Unix (s) con el reloj de la plataforma: la del sistema más el desfase del último registro o latido.
func now_unix() -> int:
	return int(Time.get_unix_time_from_system()) + _clock_offset_s


## Segundos entre latidos (los del registro).
func heartbeat_interval_s() -> float:
	return _heartbeat_s


## El conjunto del latido ahora mismo: character_id -> lease_id.
func heartbeat_set() -> Dictionary[int, String]:
	return _heartbeat_set.duplicate()


## La última reclamación (200) del personaje [param character_id], o null.
func claimed(character_id: int) -> ClaimedCharacter:
	return _claimed.get(character_id)


## El cliente HTTP (null antes de [method start]); para métricas y pruebas.
func get_client() -> PlatformClient:
	return _client


# --- Peticiones -------------------------------------------------------------------------------

## Pide la reclamación del billete de [param peer_id] (prioridad 1, sin reintento: la corta el plazo de §5.2).
## La respuesta, evento [code]claim[/code] con [code]context = {peer_id, character_id, ticket_id}[/code]. Con
## el 200, el personaje entra en el conjunto del latido.
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


## Libera sin guardar el arrendamiento [param lease_id] de [param character_id] (prioridad 1; se reintenta como
## un guardado hasta una respuesta definitiva, y un 4xx lo es). Sale del conjunto del latido si sigue siendo ese
## [param lease_id].
func release(character_id: int, lease_id: String) -> void:
	_forget_lease(character_id, lease_id)
	var body: Dictionary = {"zone_instance_id": _instance_id, "lease_id": lease_id}
	_client.submit(_request(HTTPClient.METHOD_POST, "/internal/v1/characters/%d/release" % character_id, body,
			PlatformClient.PRIORITY_ENTRY, KIND_RELEASE, {"character_id": character_id, "lease_id": lease_id},
			PlatformClient.Retry.STEADY, _on_logged))


## Manda el guardado [param body] (el sobre entero de [code]CharacterSaver[/code], §7.3) sin tocar sus bytes,
## con el mismo cuerpo en cada reintento hasta una respuesta definitiva, que sale como evento [code]save[/code]
## con [param context]. Con [param release_lease], esa respuesta saca al personaje del conjunto del latido si
## sigue siendo ese [param lease_id].
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


## Pide un bloque de ids (prioridad 2, con reintentos): evento [code]id_block[/code] con
## [code]{first, count}[/code] para [code]ProgressService[/code].
func request_id_block() -> void:
	_client.submit(_request(HTTPClient.METHOD_POST, "/internal/v1/id-blocks", {"zone_instance_id": _instance_id},
			PlatformClient.PRIORITY_PLAYER, PlatformEvent.KIND_ID_BLOCK, null, PlatformClient.Retry.STEADY, _on_event))


## Guarda el registro de una fortaleza (prioridad 3): una petición en vuelo por fortaleza, siempre con el
## registro más reciente y con [code]expected_version[/code]; con 409 [code]version_conflict[/code] toma la
## versión del error y la reenvía (§8). Cada respuesta sale como evento [code]fortress[/code].
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
		# La instancia viva manda: se reenvía su registro (el más reciente si hay uno nuevo).
		if not _fortress_latest.has(fortress_id):
			_fortress_latest[fortress_id] = (request.context as Dictionary)["record"]
	_events.append(event)
	if _fortress_latest.has(fortress_id) and not _closed:
		_send_fortress(fortress_id)


## Encola una entrada de un lote ([code]&"chat"[/code], [code]&"audit"[/code] o [code]&"war"[/code]). Si no
## trae [code]key[/code] se le pone [code]"<zone_instance_id>:<n>"[/code]; la que la trae
## ([code]op:<op_id>[/code]) la conserva. Los lotes salen cada 2 s o con 200 entradas.
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


## Una petición suelta de [param kind] ([code]&"progress_op"[/code], [code]&"progress_ledger"[/code],
## [code]&"ignore"[/code], [code]&"report"[/code] o [code]&"sanction"[/code]), sin reintento. Pone
## [code]zone_instance_id[/code] en la consulta de un GET y en el cuerpo de los demás. La respuesta, evento de
## [param kind] con [param context].
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


## Los eventos llegados desde la última llamada, en orden de llegada. En el paso «poll» del tick.
func take_events() -> Array[PlatformEvent]:
	var taken: Array[PlatformEvent] = _events
	_events = []
	return taken


## Cierre: los lotes y lo que espera su reintento salen ya.
func begin_flush() -> void:
	_flushing = true
	if _client != null:
		_client.hurry()
	_pump_batches(Time.get_ticks_msec())


## true si no queda nada en cola ni en vuelo (sin contar los latidos).
func is_flushed() -> bool:
	if _client != null and _client.pending_count(PlatformEvent.KIND_HEARTBEAT) > 0:
		return false
	for kind: StringName in _batch_queues:
		if not (_batch_queues[kind] as Array).is_empty() or _batch_in_flight[kind]:
			return false
	return _fortress_latest.is_empty()


## Manda ya un latido si no hay otro en vuelo (pruebas y herramientas).
func send_heartbeat_now() -> void:
	if _registered and not _stopped and not _heartbeat_in_flight:
		_send_heartbeat(Time.get_ticks_msec())


## El texto de un fallo para el registro: el código HTTP y el del error, o «sin respuesta».
static func describe(event: PlatformEvent) -> String:
	if not event.transport_ok:
		return "sin respuesta de la plataforma"
	if event.error_code.is_empty():
		return "HTTP %d" % event.status
	return "HTTP %d %s" % [event.status, event.error_code]


# --- Latido y lotes ---------------------------------------------------------------------------

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
	# El contexto dice por quién y cuándo se latió: los mutes de la respuesta solo valen para esos personajes y no
	# deshacen una sanción de la zona posterior (plataforma.md §9.5, P7b).
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
	# Un lease_lost ya no es de esta zona: deja de latir por él.
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


# Con más de MAX_QUEUED_BATCH_ENTRIES entradas en cola se descarta el chat más viejo (con aviso); la auditoría
# y la guerra nunca (§6).
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


# --- Auxiliares -------------------------------------------------------------------------------

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


# Saca a [param character_id] del conjunto del latido si sigue con [param lease_id].
func _forget_lease(character_id: int, lease_id: String) -> void:
	if _heartbeat_set.get(character_id, "") == lease_id:
		_heartbeat_set.erase(character_id)


# instance_lost, instance_replaced o instance_stopped (en el error o en instance_status): un solo
# instance_closed. Un instance_not_live solo se registra.
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
