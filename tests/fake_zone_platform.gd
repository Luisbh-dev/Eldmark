class_name FakeZonePlatform
extends ZonePlatform
## La plataforma falsa de las pruebas de la zona (docs/plataforma.md §14.3): todo [ZonePlatform] (colas,
## reintentos, conjunto del latido, [code]instance_closed[/code]…) con un [PlatformClient] que contesta sin red.
## Cada petición hace la ida y vuelta por JSON como con [PlatformClient] (el cuerpo se lee como lo leería la
## plataforma y la respuesta se escribe y se vuelve a leer), y su respuesta llega en el «poll» siguiente o tras
## [code]delay_s[/code]. Es la única API de pruebas de la plataforma: la usan las de los dos documentos.
## [br][br]
## [b]Por defecto[/b]: registro con [member fake_env]; GET de fortalezas con [member fake_fortresses]; cada bloque
## de ids [code]{first: next_block_first, count: 1024}[/code] (y [member next_block_first] sube 1024); claim → 200
## con lo de [method add_character] (un [code]lease_id[/code] nuevo en cada una) y, si hubo guardados, lo último
## aplicado de cada sección: [code]pvp[/code] tal cual y [code]progress[/code] sin [code]ops[/code], con los campos
## de solo lectura de la reclamación anterior y [code]location.saved_at_unix[/code] puesto (progresion.md P5a);
## sin [method add_character], 409 [code]ticket_invalid[/code]. save → 200 applied con un
## [code]save_version[/code] que sube; release → 204; heartbeat → 200 sin [code]revoked[/code] y con
## [member fake_maintenance];
## progress_op y progress_ledger → 404; lotes → 204; live y la baja → 204; PUT de fortaleza → 200 con la versión
## siguiente. La moderación (plataforma.md P7b) resuelve [code]target_name[/code] entre los personajes de
## [method add_character]: ignore → 200 [code]{ignored_account_id, name}[/code] (DELETE → 204), report → 200
## [code]{report_id}[/code] y sanction → 200 [code]{sanction_id, ends_at_unix}[/code]; un nombre que no está, 404
## [code]not_found[/code], y la propia cuenta, 400 [code]validation[/code]. [method script_next] cambia la respuesta de
## la siguiente petición de un kind.

## En [method script_next], [code]body = DEFAULT[/code] contesta lo de por defecto (con el estado y el retraso
## que se den).
const DEFAULT: StringName = &"__default__"
## Kinds que [method sent] y [method script_next] conocen, además de los de [PlatformEvent]: el registro, live,
## el GET de fortalezas, la liberación, la baja y los lotes (&"chat", &"audit", &"war").
const FAKE_LEASE_PREFIX: String = "00000000-0000-4000-8000-"

## El env del registro falso.
var fake_env: StringName = &"test"
## El primer id del bloque siguiente (cada bloque, uno en start antes de startup_finished y uno por
## request_id_block, sale como evento id_block {first, count: 1024} y sube 1024).
var next_block_first: int = 1025
## Segundos entre latidos que da el registro falso.
var fake_heartbeat_s: float = 1.0
## Lo que devuelve el GET de fortalezas: [code]{fortress_id, record, version}[/code].
var fake_fortresses: Array = []
## Si es mayor que 0, la hora Unix de [method now_unix] (y la del registro y los latidos falsos).
var fake_now_unix: int = 0
## Escala de las esperas de los reintentos del cliente falso (1 s de la tabla son 50 ms).
var fake_retry_scale: float = 0.05
## El [code]maintenance[/code] de cada latido por defecto ([code]{at_unix, message}[/code] o null; plataforma.md P5).
var fake_maintenance: Variant = null

var _characters: Dictionary[int, Dictionary] = {}
var _applied: Dictionary[int, Dictionary] = {}
var _sections: Dictionary[int, Dictionary] = {}
var _sent: Dictionary[StringName, Array] = {}
var _scripted: Dictionary[StringName, Array] = {}
var _fenced: bool = false
var _lease_counter: int = 0
var _save_versions: Dictionary[int, int] = {}
var _fake_fortress_versions: Dictionary[String, int] = {}
var _accounts: Dictionary[int, Dictionary] = {}
var _moderation_ids: int = 0


## El cliente sin red: contesta cada intento con [method FakeZonePlatform._answer] en un fotograma posterior.
class FakeClient:
	extends PlatformClient

	var fake: FakeZonePlatform = null
	var _due: Array[Dictionary] = []

	func _perform(request: PlatformClient.Request) -> void:
		var answer: Dictionary = fake._answer(request)
		_due.append({"request": request, "at": Time.get_ticks_msec() + int(float(answer["delay_s"]) * 1000.0),
				"status": answer["status"], "raw": answer["raw"]})

	func _process(delta: float) -> void:
		var now: int = Time.get_ticks_msec()
		var ready: Array[Dictionary] = []
		var waiting: Array[Dictionary] = []
		for entry: Dictionary in _due:
			if int(entry["at"]) <= now:
				ready.append(entry)
			else:
				waiting.append(entry)
		_due = waiting
		for entry: Dictionary in ready:
			var status: int = int(entry["status"])
			_complete(entry["request"], status > 0, status, entry["raw"])
		super._process(delta)


## Un error de la API (§4.1): [code]{"error": {"code", "message", …extra}}[/code].
static func error_body(code: String, message: String = "", extra: Dictionary = {}) -> Dictionary:
	var error: Dictionary = {"code": code, "message": message if not message.is_empty() else code}
	error.merge(extra)
	return {"error": error}


## Lo que devuelve la reclamación de [param character_id] (un [code]lease_id[/code] nuevo en cada una). Sin
## [param display_name], uno válido sacado del id ([method NameRules.bot_name]). [param pvp] vacío = todo a 0.
## [param progress] vacío = el de un personaje recién creado de ese reino ([method default_progress]), como el que
## devuelve [code]Load[/code] de la plataforma; uno roto se pasa tal cual (lo rechaza [code]prepare[/code]).
func add_character(character_id: int, account_id: int, role: StringName, realm: int, progress: Dictionary,
		pvp: Dictionary = {}, display_name: String = "") -> void:
	var totals: Dictionary = {}
	for key: String in ClaimedCharacter.PVP_KEYS:
		totals[key] = int(pvp.get(key, 0))
	_characters[character_id] = {
		"account_id": account_id, "role": String(role), "realm": realm,
		"progress": progress.duplicate(true) if not progress.is_empty() else default_progress(realm),
		"pvp": totals, "name": display_name if not display_name.is_empty() else NameRules.bot_name(character_id),
	}


## Lo que trae la reclamación de [param character_id] en [code]account[/code] además del rol (plataforma.md P7b):
## [code]muted_until_unix[/code] (0 sin silencio), las cuentas que ignora y los avisos sin ver
## ([code]{sanction_id, text, at_unix}[/code]). Vale para las reclamaciones siguientes.
func set_account_state(character_id: int, muted_until_unix: int, ignored_account_ids: Array = [],
		warnings: Array = []) -> void:
	var ignored: Array = []
	for id: Variant in ignored_account_ids:
		ignored.append(str(id))
	var shown: Array = []
	for warning: Dictionary in warnings:
		shown.append({"sanction_id": str(warning.get("sanction_id", 1)), "text": String(warning.get("text", "")),
				"at_unix": int(warning.get("at_unix", 0))})
	_accounts[character_id] = {"muted_until_unix": muted_until_unix, "ignored_account_ids": ignored,
			"warnings": shown}


## Las entradas del lote [param kind] ([code]&"chat"[/code], [code]&"audit"[/code] o [code]&"war"[/code]) que siguen
## en la cola, sin mandar todavía (las mandadas salen en [method sent]).
func queued(kind: StringName) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for entry: Variant in _batch_queues.get(kind, []):
		entries.append(entry)
	return entries


## La sección [code]progress[/code] de la reclamación de un personaje recién creado (progresion.md §3.4 y §14.3):
## [method ProgressRecord.new_character] con [param race_id], los 8 B de [param appearance] y
## [param starter_template_id], en la forma de [method ProgressRecord.to_claim_dictionary] (sin posición).
static func claim_progress(race_id: StringName, appearance: PackedByteArray,
		starter_template_id: StringName) -> Dictionary:
	var record: ProgressRecord = ProgressRecord.new_character()
	record.race_id = race_id
	record.appearance = appearance.duplicate()
	record.starter_template_id = starter_template_id
	return record.to_claim_dictionary(0)


## [method claim_progress] del pueblo de [param realm] (código de [enum NetProtocol.Realm]) con su apariencia por
## defecto y la primera plantilla elegible por id: lo que da [method add_character] con un [code]progress[/code]
## vacío.
static func default_progress(realm: int) -> Dictionary:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(realm))
	var race_id: StringName = race.id if race != null else &""
	var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(race_id))
	var template_id: StringName = &""
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if template != null and template.selectable \
				and (template_id.is_empty() or String(template.id) < String(template_id)):
			template_id = template.id
	return claim_progress(race_id, appearance.encode() if appearance != null else PackedByteArray([0, 0, 0, 0, 0,
			0, 0, 0]), template_id)


## La siguiente petición de [param kind] (claim, save, release, heartbeat, id_block, progress_op,
## progress_ledger, ignore, report, sanction, register, live, fortresses, fortress, chat, audit, war, stop) recibe
## esa respuesta, una vez. [param status] 0 = sin conexión ([code]transport_ok[/code] false);
## [param body] [constant DEFAULT] = la de por defecto.
func script_next(kind: StringName, status: int, body: Variant, delay_s: float = 0.0) -> void:
	if not _scripted.has(kind):
		_scripted[kind] = []
	(_scripted[kind] as Array).append({"status": status, "body": body, "delay_s": delay_s})


## [method is_fenced] devuelve [param fenced] hasta cambiarlo.
func set_fenced(fenced: bool) -> void:
	_fenced = fenced


func is_fenced() -> bool:
	return _fenced


func now_unix() -> int:
	return fake_now_unix if fake_now_unix > 0 else super.now_unix()


## El último cuerpo de guardado aplicado de [param character_id]; {} si ninguno.
func applied(character_id: int) -> Dictionary:
	return (_applied.get(character_id, {}) as Dictionary).duplicate(true)


## Los cuerpos recibidos de [param kind], en orden (un GET, [code]{"path": …}[/code]).
func sent(kind: StringName) -> Array[Dictionary]:
	var bodies: Array[Dictionary] = []
	for body: Variant in _sent.get(kind, []):
		bodies.append(body)
	return bodies


func _make_client() -> PlatformClient:
	var client := FakeClient.new()
	client.fake = self
	client.retry_scale = fake_retry_scale
	return client


# La respuesta de un intento: {status, raw, delay_s}, con la ida y vuelta por JSON.
func _answer(request: PlatformClient.Request) -> Dictionary:
	var kind: StringName = request.kind
	var body: Dictionary = {}
	if request.body.is_empty():
		body = {"path": request.path}
	else:
		var parsed: Dictionary = PlatformJson.parse(request.body)
		body = parsed["data"] if parsed["ok"] and parsed["data"] is Dictionary else {}
	if not _sent.has(kind):
		_sent[kind] = []
	(_sent[kind] as Array).append(body)
	var status: int = 0
	var response: Variant = null
	var delay_s: float = 0.0
	var queue: Array = _scripted.get(kind, [])
	if not queue.is_empty():
		var scripted: Dictionary = queue.pop_front()
		status = int(scripted["status"])
		delay_s = float(scripted["delay_s"])
		if scripted["body"] is StringName and scripted["body"] == DEFAULT:
			response = _default_answer(kind, request, body)[1]
		else:
			response = scripted["body"]
	else:
		var answer: Array = _default_answer(kind, request, body)
		status = answer[0]
		response = answer[1]
	if status == 200 and kind == PlatformEvent.KIND_SAVE and response is Dictionary \
			and bool((response as Dictionary).get("applied", false)):
		_remember_save(body)
	var raw := PackedByteArray()
	if status > 0 and status != 204 and response != null:
		raw = (response if response is String else JSON.stringify(response)).to_utf8_buffer()
	return {"status": status, "raw": raw, "delay_s": delay_s}


# [status, cuerpo] por defecto de cada kind.
func _default_answer(kind: StringName, request: PlatformClient.Request, body: Dictionary) -> Array:
	match kind:
		ZonePlatform.KIND_REGISTER:
			return [200, {"zone_instance_id": "00000000-0000-4000-8000-0000000000f5", "env": String(fake_env),
					"heartbeat_s": fake_heartbeat_s, "lease_ttl_s": 30, "now_unix": now_unix()}]
		ZonePlatform.KIND_FORTRESSES:
			return [200, {"fortresses": fake_fortresses}]
		PlatformEvent.KIND_ID_BLOCK:
			var first: int = next_block_first
			next_block_first += 1024
			return [200, {"first": str(first), "count": 1024}]
		ZonePlatform.KIND_LIVE, ZonePlatform.KIND_STOP, ZonePlatform.KIND_RELEASE, &"chat", &"audit", &"war":
			return [204, null]
		PlatformEvent.KIND_HEARTBEAT:
			return [200, {"now_unix": now_unix(), "revoked": [], "mutes": [], "maintenance": fake_maintenance}]
		PlatformEvent.KIND_CLAIM:
			return _claim_answer(body)
		PlatformEvent.KIND_SAVE:
			var character_id: int = PlatformJson.id_of(body.get("character_id"))
			var version: int = _save_versions.get(character_id, 0) + 1
			_save_versions[character_id] = version
			return [200, {"applied": true, "duplicate": false, "save_version": version, "instance_status": "live"}]
		PlatformEvent.KIND_FORTRESS:
			var fortress_id: String = request.path.get_file().uri_decode()
			var version: int = _fake_fortress_versions.get(fortress_id, 0) + 1
			_fake_fortress_versions[fortress_id] = version
			return [200, {"version": version}]
		PlatformEvent.KIND_IGNORE, PlatformEvent.KIND_REPORT, PlatformEvent.KIND_SANCTION:
			return _moderation_answer(kind, request, body)
	return [404, error_body("not_found", "No existe")]


# Ignorados, reportes y sanciones por defecto: el nombre se resuelve entre los personajes dados de alta.
func _moderation_answer(kind: StringName, request: PlatformClient.Request, body: Dictionary) -> Array:
	var author_key: String = {PlatformEvent.KIND_IGNORE: "character_id", PlatformEvent.KIND_REPORT:
			"reporter_character_id", PlatformEvent.KIND_SANCTION: "author_character_id"}[kind]
	var author: Dictionary = _characters.get(PlatformJson.id_of(body.get(author_key)), {})
	var wanted: String = NameRules.normalize_key(PlatformJson.text_in(body, "target_name"))
	var target_id: int = 0
	for character_id: int in _characters:
		if NameRules.normalize_key(String(_characters[character_id]["name"])) == wanted:
			target_id = character_id
	if kind == PlatformEvent.KIND_IGNORE and request.method == HTTPClient.METHOD_DELETE:
		return [204, null]
	if target_id == 0:
		return [404, error_body("not_found", "No hay nadie con ese nombre")]
	var target: Dictionary = _characters[target_id]
	if kind != PlatformEvent.KIND_SANCTION and not author.is_empty() \
			and int(author["account_id"]) == int(target["account_id"]):
		return [400, error_body("validation", "Datos no válidos", {"fields": {"target_name": "self"}})]
	_moderation_ids += 1
	match kind:
		PlatformEvent.KIND_IGNORE:
			return [200, {"ignored_account_id": str(target["account_id"]), "name": target["name"]}]
		PlatformEvent.KIND_REPORT:
			return [200, {"report_id": str(_moderation_ids)}]
	var minutes: int = int(body.get("minutes", 0))
	var ends_at: Variant = null
	if minutes > 0:
		ends_at = now_unix() + minutes * 60
	return [200, {"sanction_id": str(_moderation_ids), "ends_at_unix": ends_at}]


func _claim_answer(body: Dictionary) -> Array:
	var character_id: int = PlatformJson.id_of(body.get("character_id"))
	if not PlatformJson.is_id(body.get("ticket_id")) or not _characters.has(character_id):
		return [409, error_body("ticket_invalid", "Billete no válido")]
	var data: Dictionary = _characters[character_id]
	_lease_counter += 1
	var sections: Dictionary = _sections.get(character_id, {})
	var account: Dictionary = _accounts.get(character_id, {})
	return [200, {
		"lease_id": FAKE_LEASE_PREFIX + "%012d" % _lease_counter,
		"instance_status": "live",
		"account": {"account_id": str(data["account_id"]), "role": data["role"],
				"muted_until_unix": int(account.get("muted_until_unix", 0)),
				"ignored_account_ids": account.get("ignored_account_ids", []), "warnings": account.get("warnings", [])},
		"character": {"character_id": str(character_id), "world_id": _config.world_id if _config != null else 1,
				"realm": data["realm"], "name": data["name"]},
		"progress": sections.get("progress", data["progress"]),
		"pvp": sections.get("pvp", data["pvp"]),
	}]


# Guarda lo último aplicado de cada sección para la reclamación siguiente (plataforma.md §14.1): pvp tal cual y
# progress como la daría Load (progresion.md §3.4): sin ops, con los campos de solo lectura de la reclamación
# anterior y location.saved_at_unix con la hora del guardado.
func _remember_save(body: Dictionary) -> void:
	var character_id: int = PlatformJson.id_of(body.get("character_id"))
	if character_id < 1:
		return
	_applied[character_id] = body.duplicate(true)
	var sections: Dictionary = _sections.get(character_id, {})
	if body.get("pvp") is Dictionary:
		sections["pvp"] = (body["pvp"] as Dictionary).duplicate(true)
	if body.get("progress") is Dictionary:
		var previous: Dictionary = sections.get("progress",
				(_characters[character_id]["progress"] if _characters.has(character_id) else {}))
		var progress: Dictionary = (body["progress"] as Dictionary).duplicate(true)
		progress.erase("ops")
		for key: String in ProgressRecord.CLAIM_ONLY_KEYS:
			if previous.has(key):
				progress[key] = previous[key]
		if progress.get("location") is Dictionary:
			(progress["location"] as Dictionary)[ProgressRecord.LOCATION_CLAIM_KEY] = now_unix()
		sections["progress"] = progress
	_sections[character_id] = sections
