class_name FakeZonePlatform
extends ZonePlatform
## The fake platform for the zone tests (docs/plataforma.md §14.3): the whole [ZonePlatform]
## (queues, retries, heartbeat set, [code]instance_closed[/code]…) with a [PlatformClient] that
## answers without a network. Each request makes the round trip through JSON as with
## [PlatformClient] (the body is read as the platform would read it and the response is written
## and read back), and its response arrives on the next "poll" or after [code]delay_s[/code]. It is
## the only platform test API: the tests of both documents use it.
## [br][br]
## [b]By default[/b]: register with [member fake_env]; fort GET with [member fake_fortresses];
## each id block [code]{first: next_block_first, count: 1024}[/code] (and [member next_block_first]
## rises by 1024); claim → 200 with what [method add_character] set (a new [code]lease_id[/code] on
## each one) and, if there were saves, the last applied of each section: [code]pvp[/code] as is and
## [code]progress[/code] without [code]ops[/code], with the read-only fields of the previous claim
## and [code]location.saved_at_unix[/code] set (progresion.md P5a); without [method add_character],
## 409 [code]ticket_invalid[/code]. save → 200 applied with a rising [code]save_version[/code];
## release → 204; heartbeat → 200 without [code]revoked[/code] and with [member fake_maintenance];
## progress_op and progress_ledger → 404; batches → 204; live and the deregistration → 204; fort
## PUT → 200 with the next version. Moderation (plataforma.md P7b) resolves [code]target_name[/code]
## among the characters of [method add_character]: ignore → 200
## [code]{ignored_account_id, name}[/code] (DELETE → 204), report → 200 [code]{report_id}[/code]
## and sanction → 200 [code]{sanction_id, ends_at_unix}[/code]; a name that is not there, 404
## [code]not_found[/code], and the account's own, 400 [code]validation[/code].
## [method script_next] changes the response to the next request of a kind.

## In [method script_next], [code]body = DEFAULT[/code] answers the default (with the status and
## the delay given).
const DEFAULT: StringName = &"__default__"
## Kinds that [method sent] and [method script_next] know, besides those of [PlatformEvent]:
## register, live, the fort GET, release, deregistration and batches (&"chat", &"audit", &"war").
const FAKE_LEASE_PREFIX: String = "00000000-0000-4000-8000-"

## The env of the fake registration.
var fake_env: StringName = &"test"
## The first id of the next block (each block, one in start before startup_finished and one per
## request_id_block, comes out as an id_block event {first, count: 1024} and rises by 1024).
var next_block_first: int = 1025
## Seconds between heartbeats given by the fake registration.
var fake_heartbeat_s: float = 1.0
## What the fort GET returns: [code]{fortress_id, record, version}[/code].
var fake_fortresses: Array = []
## If greater than 0, the Unix time of [method now_unix] (and that of the fake registration and
## heartbeats).
var fake_now_unix: int = 0
## Scale of the fake client's retry waits (1 s in the table is 50 ms).
var fake_retry_scale: float = 0.05
## The [code]maintenance[/code] of each default heartbeat ([code]{at_unix, message}[/code] or null;
## plataforma.md P5).
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


## The network-less client: it answers each attempt with [method FakeZonePlatform._answer] on a
## later frame.
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


## An API error (§4.1): [code]{"error": {"code", "message", …extra}}[/code].
static func error_body(code: String, message: String = "", extra: Dictionary = {}) -> Dictionary:
	var error: Dictionary = {"code": code, "message": message if not message.is_empty() else code}
	error.merge(extra)
	return {"error": error}


## What the claim of [param character_id] returns (a new [code]lease_id[/code] on each one).
## Without [param display_name], a valid one derived from the id ([method NameRules.bot_name]).
## Empty [param pvp] = all 0. Empty [param progress] = that of a newly created character of that
## realm ([method default_progress]), like the one the platform's [code]Load[/code] returns; a
## broken one is passed as is ([code]prepare[/code] rejects it).
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


## What the claim of [param character_id] brings in [code]account[/code] besides the role
## (plataforma.md P7b): [code]muted_until_unix[/code] (0 no mute), the accounts it ignores and the
## unseen notices ([code]{sanction_id, text, at_unix}[/code]). It applies to subsequent claims.
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


## The entries of batch [param kind] ([code]&"chat"[/code], [code]&"audit"[/code] or
## [code]&"war"[/code]) that are still queued, not yet sent (the sent ones appear in
## [method sent]).
func queued(kind: StringName) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for entry: Variant in _batch_queues.get(kind, []):
		entries.append(entry)
	return entries


## The [code]progress[/code] section of the claim of a newly created character (progresion.md §3.4
## and §14.3): [method ProgressRecord.new_character] with [param race_id], the 8 B of
## [param appearance] and [param starter_template_id], in the form of
## [method ProgressRecord.to_claim_dictionary] (without position).
static func claim_progress(race_id: StringName, appearance: PackedByteArray,
		starter_template_id: StringName) -> Dictionary:
	var record: ProgressRecord = ProgressRecord.new_character()
	record.race_id = race_id
	record.appearance = appearance.duplicate()
	record.starter_template_id = starter_template_id
	return record.to_claim_dictionary(0)


## [method claim_progress] of the people of [param realm] ([enum NetProtocol.Realm] code) with its
## default appearance and the first selectable template by id: what [method add_character] gives
## with an empty [code]progress[/code].
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


## The next request of [param kind] (claim, save, release, heartbeat, id_block, progress_op,
## progress_ledger, ignore, report, sanction, register, live, fortresses, fortress, chat, audit,
## war, stop) receives that response, once. [param status] 0 = offline ([code]transport_ok[/code]
## false); [param body] [constant DEFAULT] = the default one.
func script_next(kind: StringName, status: int, body: Variant, delay_s: float = 0.0) -> void:
	if not _scripted.has(kind):
		_scripted[kind] = []
	(_scripted[kind] as Array).append({"status": status, "body": body, "delay_s": delay_s})


## [method is_fenced] returns [param fenced] until changed.
func set_fenced(fenced: bool) -> void:
	_fenced = fenced


func is_fenced() -> bool:
	return _fenced


func now_unix() -> int:
	return fake_now_unix if fake_now_unix > 0 else super.now_unix()


## The last applied save body of [param character_id]; {} if none.
func applied(character_id: int) -> Dictionary:
	return (_applied.get(character_id, {}) as Dictionary).duplicate(true)


## The bodies received of [param kind], in order (a GET, [code]{"path": …}[/code]).
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


# The response to an attempt: {status, raw, delay_s}, with the round trip through JSON.
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


# Default [status, body] of each kind.
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
	return [404, error_body("not_found", "Does not exist")]


# Default ignores, reports and sanctions: the name is resolved among the registered characters.
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
		return [404, error_body("not_found", "There is nobody with that name")]
	var target: Dictionary = _characters[target_id]
	if kind != PlatformEvent.KIND_SANCTION and not author.is_empty() \
			and int(author["account_id"]) == int(target["account_id"]):
		return [400, error_body("validation", "Invalid data", {"fields": {"target_name": "self"}})]
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
		return [409, error_body("ticket_invalid", "Invalid ticket")]
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


# Stores the last applied of each section for the next claim (plataforma.md §14.1): pvp as is and
# progress as Load would give it (progresion.md §3.4): without ops, with the read-only fields of
# the previous claim and location.saved_at_unix with the save time.
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
