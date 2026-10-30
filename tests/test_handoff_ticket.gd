extends TestCase
## Pruebas del billete de 52 B ([HandoffTicket]) con los vectores que genera la plataforma en Go
## ([code]tests/fixtures/tickets/handoff_ticket_vectors.json[/code]) y de [TicketAuthProvider]: firma alterada,
## clave desconocida, otra zona, caducado, desfase de 5 s, reutilizado, otro personaje, zona cercada y las
## respuestas de la reclamación (docs/plataforma.md §5.1, §5.2 y §15 P4). Sin red: [FakeZonePlatform].

const VECTORS_PATH: String = "res://tests/fixtures/tickets/handoff_ticket_vectors.json"
## La hora del vector de §5.1 (emitido en 1800000000, caduca en 1800000010).
const VECTOR_NOW: int = 1800000005

var _vectors: Dictionary = {}
var _keys: Dictionary[int, PackedByteArray] = {}
var _platform: FakeZonePlatform = null
var _next_ticket_id: int = 1000


func before_each() -> void:
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(VECTORS_PATH)), OK, "los vectores se leen")
	_vectors = json.data
	_keys = {}
	for entry: Dictionary in _vectors["keys"]:
		_keys[int(entry["key_id"])] = String(entry["hex"]).hex_decode()


func after_each() -> void:
	if is_instance_valid(_platform):
		_platform.get_parent().remove_child(_platform)
		_platform.free()
	_platform = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## Una plataforma falsa ya arrancada para la zona [param zone_id] (mundo 1, canal 0) con su reloj en
## [param now].
func _start_platform(zone_id: String = "vado_gris", now: int = VECTOR_NOW) -> FakeZonePlatform:
	_platform = FakeZonePlatform.new()
	_platform.fake_now_unix = now
	_platform.log_sink = func(_text: String) -> void: pass
	tree.root.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = zone_id
	config.platform_url = "http://fake"
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": _keys})
	for _i: int in 60:
		if not finished.is_empty():
			break
		await wait_process_frames()
	assert_eq(finished, [[true, ""]], "la plataforma falsa arranca")
	return _platform


func _provider(zone_id: String = "vado_gris", world_id: int = 1, channel: int = 0) -> TicketAuthProvider:
	var provider := TicketAuthProvider.new(_platform, world_id, zone_id, channel, _keys)
	provider.log_sink = func(_text: String) -> void: pass
	return provider


## Un billete firmado con la clave 1 para [param character_id] en [param zone_id], emitido en [param issued_at]
## (caduca 10 s después), con un ticket_id nuevo.
func _ticket(character_id: int, issued_at: int, zone_id: String = "vado_gris", world_id: int = 1,
		channel: int = 0, lifetime: int = 10) -> PackedByteArray:
	_next_ticket_id += 1
	var ticket := HandoffTicket.new()
	ticket.key_id = 1
	ticket.world_id = world_id
	ticket.ticket_id = _next_ticket_id
	ticket.character_id = character_id
	ticket.zone_key = HandoffTicket.zone_key_of(zone_id)
	ticket.channel = channel
	ticket.realm = NetProtocol.Realm.VARDHEIM
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = issued_at
	ticket.expires_at = issued_at + lifetime
	return ticket.sign(_keys[1])


func _hello(character_id: int, ticket: PackedByteArray) -> NetMessages.Hello:
	var hello := NetMessages.Hello.new()
	hello.realm = NetProtocol.Realm.SOLMARCH
	hello.display_name = "Cualquiera"
	hello.character_id = character_id
	hello.ticket = ticket
	return hello


## Avanza al menos [param frames] fotogramas y [param min_ms] ms y reparte los eventos de la plataforma al
## proveedor; devuelve sus finales.
func _drain(provider: TicketAuthProvider, frames: int = 4, min_ms: int = 0) -> Array[AuthOutcome]:
	var started: int = Time.get_ticks_msec()
	await wait_process_frames(frames)
	while Time.get_ticks_msec() - started < min_ms:
		await wait_process_frames()
	for event: PlatformEvent in _platform.take_events():
		provider.on_platform_event(event)
	return provider.take_completed()


# --- Billete ----------------------------------------------------------------------------------

func test_shared_vectors_decode_sign_and_verify() -> void:
	var valid: Array = _vectors["valid"]
	assert_eq(valid.size(), 3, "tres vectores válidos")
	for entry: Dictionary in valid:
		var label: String = entry["name"]
		var bytes: PackedByteArray = String(entry["hex"]).hex_decode()
		assert_eq(bytes, Marshalls.base64_to_raw(entry["base64"]), "%s: el base64 es el mismo billete" % label)
		var ticket: HandoffTicket = HandoffTicket.decode(bytes)
		if not assert_not_null(ticket, "%s: se decodifica" % label):
			continue
		assert_eq(ticket.version, 1, label)
		assert_eq(ticket.key_id, int(entry["key_id"]), "%s: key_id" % label)
		assert_eq(ticket.world_id, int(entry["world_id"]), "%s: world_id" % label)
		assert_eq(ticket.ticket_id, String(entry["ticket_id"]).to_int(), "%s: ticket_id (cadena)" % label)
		assert_eq(ticket.character_id, String(entry["character_id"]).to_int(), "%s: character_id" % label)
		assert_eq(ticket.zone_key, int(entry["zone_key"]), "%s: zone_key" % label)
		assert_eq(ticket.zone_key, HandoffTicket.zone_key_of(entry["zone_id"]), "%s: la huella de la zona" % label)
		assert_eq([ticket.channel, ticket.realm, ticket.arrival, ticket.flags],
				[int(entry["channel"]), int(entry["realm"]), int(entry["arrival"]), int(entry["flags"])],
				"%s: canal, reino, llegada y flags" % label)
		assert_eq([ticket.issued_at, ticket.expires_at], [int(entry["issued_at"]), int(entry["expires_at"])],
				"%s: fechas (u32)" % label)
		assert_true(ticket.verify(bytes, _keys), "%s: la firma vale" % label)
		assert_eq(ticket.sign(_keys[ticket.key_id]), bytes, "%s: firmar da los mismos 52 B que Go" % label)
	var first: HandoffTicket = HandoffTicket.decode(String(valid[0]["hex"]).hex_decode())
	assert_eq(first.ticket_id, 0x0102030405060708, "el ticket_id del vector de §5.1")
	assert_eq(first.zone_key, 0x19efc013, "vado_gris da 0x19efc013")
	var big: HandoffTicket = HandoffTicket.decode(String(valid[1]["hex"]).hex_decode())
	assert_eq(big.ticket_id, 9223372036854775807, "ticket_id de 2^63 − 1 con to_int()")
	assert_eq(big.character_id, 9007199254740993, "character_id de 2^53 + 1, sin perder precisión")


func test_zone_keys_match_go() -> void:
	for entry: Dictionary in _vectors["zone_keys"]:
		assert_eq(HandoffTicket.zone_key_of(entry["zone_id"]), int(entry["zone_key"]),
				"la huella de '%s'" % entry["zone_id"])


func test_invalid_vectors_are_rejected() -> void:
	var invalid: Array = _vectors["invalid"]
	assert_eq(invalid.size(), 9, "nueve vectores no válidos")
	for entry: Dictionary in invalid:
		var bytes: PackedByteArray = String(entry["hex"]).hex_decode()
		var ticket: HandoffTicket = HandoffTicket.decode(bytes)
		match String(entry["error"]):
			"size", "version":
				assert_null(ticket, "%s: no se decodifica" % entry["name"])
			"key", "mac":
				if assert_not_null(ticket, "%s: se decodifica" % entry["name"]):
					assert_false(ticket.verify(bytes, _keys), "%s: la firma no vale" % entry["name"])
			_:
				fail("error desconocido en los vectores: %s" % entry["error"])
	var vector: PackedByteArray = String(_vectors["valid"][0]["hex"]).hex_decode()
	var decoded: HandoffTicket = HandoffTicket.decode(vector)
	var no_keys: Dictionary[int, PackedByteArray] = {}
	assert_false(decoded.verify(vector, no_keys), "sin claves no vale nada")
	var other_bytes: PackedByteArray = vector.duplicate()
	other_bytes[51] ^= 1
	assert_false(decoded.verify(other_bytes, _keys), "verify mira los bytes que se le dan")


# --- TicketAuthProvider -----------------------------------------------------------------------

func test_vector_ticket_is_pending_and_claimed_once() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	var vector: PackedByteArray = String(_vectors["valid"][0]["hex"]).hex_decode()
	assert_true(provider.uses_tickets(), "usa billetes")
	assert_eq(provider.authenticate(5, _hello(42, vector)), AuthProvider.PENDING, "el vector pasa: PENDING")
	assert_eq(provider.pending_count(), 1, "el peer espera su reclamación")
	await wait_process_frames(2)
	var claims: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_CLAIM)
	assert_eq(claims, [{"zone_instance_id": _platform.instance_id(), "ticket_id": "72623859790382856",
			"character_id": "42"}], "una reclamación con los ids en cadena")
	assert_eq(provider.authenticate(6, _hello(42, vector)), NetProtocol.Result.TICKET,
			"el mismo billete otra vez: reutilizado")
	assert_eq(provider.last_rejection, "reutilizado")
	await wait_process_frames(2)
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 1, "y no llega a la plataforma")


func test_altered_signature_unknown_key_and_missing_ticket_never_reach_the_platform() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	var good: PackedByteArray = _ticket(42, VECTOR_NOW)
	var altered: PackedByteArray = good.duplicate()
	altered[40] ^= 0x01
	assert_eq(provider.authenticate(1, _hello(42, altered)), NetProtocol.Result.TICKET, "firma alterada")
	assert_eq(provider.last_rejection, "firma")
	var body_changed: PackedByteArray = good.duplicate()
	body_changed[12] = 43
	assert_eq(provider.authenticate(1, _hello(43, body_changed)), NetProtocol.Result.TICKET,
			"otro personaje con la firma del 42")
	var unknown: PackedByteArray = good.duplicate()
	unknown[1] = 9
	assert_eq(provider.authenticate(1, _hello(42, unknown)), NetProtocol.Result.TICKET, "clave desconocida")
	assert_eq(provider.authenticate(1, _hello(42, good.slice(0, 51))), NetProtocol.Result.TICKET, "51 B")
	assert_eq(provider.authenticate(1, _hello(42, PackedByteArray())), NetProtocol.Result.TICKET, "sin billete")
	assert_eq(provider.last_rejection, "sin billete")
	await wait_process_frames(3)
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 0, "nada llega a la plataforma")
	assert_eq(provider.authenticate(1, _hello(42, good)), AuthProvider.PENDING, "el bueno sí pasa")


func test_ticket_of_another_zone_world_or_channel_is_rejected() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	assert_eq(provider.authenticate(1, _hello(42, _ticket(42, VECTOR_NOW, "test_world"))),
			NetProtocol.Result.TICKET, "otra zona")
	assert_eq(provider.last_rejection, "otra zona")
	assert_eq(provider.authenticate(1, _hello(42, _ticket(42, VECTOR_NOW, "vado_gris", 2))),
			NetProtocol.Result.TICKET, "otro mundo")
	assert_eq(provider.authenticate(1, _hello(42, _ticket(42, VECTOR_NOW, "vado_gris", 1, 3))),
			NetProtocol.Result.TICKET, "otro canal")
	var channel_three: TicketAuthProvider = _provider("vado_gris", 1, 3)
	assert_eq(channel_three.authenticate(1, _hello(42, _ticket(42, VECTOR_NOW, "vado_gris", 1, 3))),
			AuthProvider.PENDING, "el del canal 3 vale en el canal 3")


func test_expired_tickets_and_the_five_second_clock_skew() -> void:
	await _start_platform("vado_gris", 1800000100)
	var provider: TicketAuthProvider = _provider()
	var now: int = _platform.now_unix()
	assert_eq(provider.authenticate(1, _hello(42, _ticket(42, now - 15))), AuthProvider.PENDING,
			"caducado hace 5 s: aún vale (desfase de 5 s)")
	assert_eq(provider.authenticate(2, _hello(42, _ticket(42, now - 16))), NetProtocol.Result.TICKET,
			"caducado hace 6 s: no")
	assert_eq(provider.last_rejection, "caducado")
	assert_eq(provider.authenticate(3, _hello(42, _ticket(42, now + 5))), AuthProvider.PENDING,
			"emitido 5 s en el futuro (reloj de la plataforma adelantado): vale")
	assert_eq(provider.authenticate(4, _hello(42, _ticket(42, now + 6))), NetProtocol.Result.TICKET,
			"6 s en el futuro: no")
	_platform.fake_now_unix = now + 100
	var vector: PackedByteArray = String(_vectors["valid"][0]["hex"]).hex_decode()
	assert_eq(provider.authenticate(5, _hello(42, vector)), NetProtocol.Result.TICKET,
			"el vector de 1800000000 con el reloj 100 s después")


func test_reused_ticket_is_rejected_for_thirty_seconds() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	var now: int = _platform.now_unix()
	var long_lived: PackedByteArray = _ticket(42, now, "vado_gris", 1, 0, 100)
	assert_eq(provider.authenticate(1, _hello(42, long_lived)), AuthProvider.PENDING, "la primera vez")
	_platform.fake_now_unix = now + 30
	assert_eq(provider.authenticate(2, _hello(42, long_lived)), NetProtocol.Result.TICKET,
			"30 s después: reutilizado")
	_platform.fake_now_unix = now + 31
	assert_eq(provider.authenticate(3, _hello(42, long_lived)), AuthProvider.PENDING,
			"pasados 30 s la zona lo olvida (el un solo uso lo garantiza la plataforma)")


func test_character_of_the_hello_must_match_and_a_fenced_zone_is_unavailable() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	assert_eq(provider.authenticate(1, _hello(41, _ticket(42, VECTOR_NOW))), NetProtocol.Result.TICKET,
			"el HELLO dice otro personaje")
	assert_eq(provider.last_rejection, "personaje")
	_platform.set_fenced(true)
	assert_eq(provider.authenticate(2, _hello(42, _ticket(42, VECTOR_NOW))), NetProtocol.Result.UNAVAILABLE,
			"zona cercada: UNAVAILABLE antes de mirar el billete")
	assert_eq(provider.authenticate(2, _hello(42, PackedByteArray())), NetProtocol.Result.UNAVAILABLE,
			"también sin billete")
	await wait_process_frames(3)
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 0, "nada llega a la plataforma")


func test_claim_responses_become_outcomes() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	_platform.add_character(42, 7, &"gm", NetProtocol.Realm.VARDHEIM, {"level": 3},
			{"kills": 4, "gate_damage": 9007199254740991}, "Aneira")
	var cases: Array = [
		[409, FakeZonePlatform.error_body("ticket_invalid"), NetProtocol.Result.TICKET, ""],
		[409, FakeZonePlatform.error_body("character_busy"), NetProtocol.Result.BUSY, ""],
		[403, FakeZonePlatform.error_body("account_blocked",
				"Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC: insultos",
				{"kind": "suspension", "until_unix": 1793728800, "reason": "insultos"}), NetProtocol.Result.BANNED,
				"Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC: insultos"],
		[403, FakeZonePlatform.error_body("account_blocked", "Tu cuenta está expulsada: trampas",
				{"kind": "ban", "until_unix": null, "reason": "trampas"}), NetProtocol.Result.BANNED,
				"Tu cuenta está expulsada: trampas"],
		[503, FakeZonePlatform.error_body("db_unavailable"), NetProtocol.Result.UNAVAILABLE, ""],
		[0, null, NetProtocol.Result.UNAVAILABLE, ""],
		[409, FakeZonePlatform.error_body("instance_not_live"), NetProtocol.Result.UNAVAILABLE, ""],
		[400, FakeZonePlatform.error_body("validation"), NetProtocol.Result.UNAVAILABLE, ""],
	]
	var peer_id: int = 100
	for entry: Array in cases:
		peer_id += 1
		_platform.script_next(PlatformEvent.KIND_CLAIM, entry[0], entry[1])
		assert_eq(provider.authenticate(peer_id, _hello(42, _ticket(42, VECTOR_NOW))), AuthProvider.PENDING)
		var outcomes: Array[AuthOutcome] = await _drain(provider)
		if not assert_eq(outcomes.size(), 1, "un final para %d %s" % [entry[0], str(entry[1])]):
			continue
		assert_eq([outcomes[0].peer_id, outcomes[0].result, outcomes[0].text], [peer_id, entry[2], entry[3]],
				"%d %s" % [entry[0], str(entry[1])])
		assert_null(outcomes[0].claimed, "sin personaje")
	# El 200: el personaje de la reclamación, con los ids y enteros leídos tras la ida y vuelta por JSON.
	assert_eq(provider.authenticate(200, _hello(42, _ticket(42, VECTOR_NOW))), AuthProvider.PENDING)
	var ok: Array[AuthOutcome] = await _drain(provider)
	if assert_eq(ok.size(), 1, "un final del 200") and assert_eq(ok[0].result, NetProtocol.Result.OK):
		var claimed: ClaimedCharacter = ok[0].claimed
		assert_eq([claimed.character_id, claimed.account_id, claimed.realm, claimed.display_name, claimed.role],
				[42, 7, NetProtocol.Realm.VARDHEIM, "Aneira", &"gm"], "cuenta y personaje")
		assert_true(claimed.is_staff(), "un gm es del personal del juego")
		assert_eq(claimed.pvp["kills"], 4, "pvp con int()")
		assert_eq(claimed.pvp["gate_damage"], 9007199254740991, "hasta 2^53 − 1")
		assert_eq(typeof(claimed.pvp["kills"]), TYPE_INT, "enteros, no float")
		assert_eq(claimed.progress, {"level": 3.0}, "progress llega tal cual (la lee ProgressRecord)")
		assert_eq(_platform.heartbeat_set(), {42: claimed.lease_id}, "y entra en el conjunto del latido")


func test_a_claim_that_arrives_after_the_peer_left_is_released() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	_platform.add_character(42, 7, &"player", NetProtocol.Realm.VARDHEIM, {})
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 0.2)
	assert_eq(provider.authenticate(9, _hello(42, _ticket(42, VECTOR_NOW))), AuthProvider.PENDING)
	provider.cancel(9)
	assert_eq(provider.pending_count(), 0, "ya no espera")
	var outcomes: Array[AuthOutcome] = await _drain(provider, 4, 300)
	assert_eq(outcomes.size(), 0, "ningún final para un peer que se fue")
	await wait_process_frames(3)
	var releases: Array[Dictionary] = _platform.sent(ZonePlatform.KIND_RELEASE)
	var claimed: ClaimedCharacter = _platform.claimed(42)
	if assert_not_null(claimed, "la reclamación llegó") and assert_eq(releases.size(), 1, "y se libera"):
		assert_eq(releases[0], {"zone_instance_id": _platform.instance_id(), "lease_id": claimed.lease_id},
				"con su lease_id")
	assert_true(_platform.heartbeat_set().is_empty(), "y sale del conjunto del latido")


func test_a_claim_body_that_does_not_parse_is_unavailable_and_released() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, {"lease_id": "abc", "account": {}, "character": {}})
	assert_eq(provider.authenticate(3, _hello(42, _ticket(42, VECTOR_NOW))), AuthProvider.PENDING)
	var outcomes: Array[AuthOutcome] = await _drain(provider)
	if assert_eq(outcomes.size(), 1):
		assert_eq(outcomes[0].result, NetProtocol.Result.UNAVAILABLE, "un cuerpo que no se entiende")
	await wait_process_frames(3)
	assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE), [{"zone_instance_id": _platform.instance_id(),
			"lease_id": "abc"}], "se libera el lease_id que traiga")


func test_claimed_character_reads_ids_beyond_2_53_and_rejects_bad_bodies() -> void:
	var body: Dictionary = {
		"lease_id": "0b9d6a2e-8f0c-4c5b-9d43-3d0f1e2a4b5c", "instance_status": "live",
		"account": {"account_id": "9223372036854775807", "role": "moderator", "muted_until_unix": 253402300799.0,
				"ignored_account_ids": ["9007199254740993", "5"],
				"warnings": [{"sanction_id": "12", "text": "Has recibido un aviso", "at_unix": 1800000000}]},
		"character": {"character_id": "9007199254740993", "world_id": 1.0, "realm": 2, "name": "Bruna"},
		"progress": null,
		"pvp": {"kills": 1, "deaths": 2.0, "assists": 3, "captures": 4, "gate_damage": 5, "defend_s": 6},
	}
	var claimed: ClaimedCharacter = ClaimedCharacter.from_claim(body)
	if assert_not_null(claimed, "el cuerpo se lee"):
		assert_eq(claimed.character_id, 9007199254740993, "character_id > 2^53 sin perder precisión")
		assert_eq(claimed.account_id, 9223372036854775807, "account_id de 2^63 − 1")
		assert_eq(claimed.ignored_accounts, PackedInt64Array([9007199254740993, 5]), "ignorados")
		assert_eq(claimed.muted_until_unix, 253402300799, "silencio sin fin")
		assert_eq(claimed.realm, NetProtocol.Realm.SOLMARCH)
		assert_eq(claimed.world_id, 1)
		assert_eq(claimed.progress, {}, "progress null es vacío")
		assert_eq(claimed.warnings, [{"sanction_id": 12, "text": "Has recibido un aviso", "at_unix": 1800000000}],
				"los avisos de la moderación")
		assert_true(claimed.is_staff(), "un moderador es del personal")
	var broken: Array = [
		["account", "account_id", 5], ["account", "account_id", "9223372036854775808"],
		["account", "account_id", "007"], ["account", "role", "superadmin"], ["character", "realm", 4],
		["character", "name", ""], ["character", "character_id", "-1"], ["pvp", "kills", 1.5],
		["pvp", "defend_s", -1], ["account", "ignored_account_ids", [1]],
	]
	for entry: Array in broken:
		var copy: Dictionary = body.duplicate(true)
		(copy[entry[0]] as Dictionary)[entry[1]] = entry[2]
		assert_null(ClaimedCharacter.from_claim(copy), "%s.%s = %s no vale" % [entry[0], entry[1], str(entry[2])])
	var no_progress: Dictionary = body.duplicate(true)
	no_progress.erase("progress")
	assert_null(ClaimedCharacter.from_claim(no_progress), "sin progress no vale")
	var no_lease: Dictionary = body.duplicate(true)
	no_lease["lease_id"] = 7
	assert_null(ClaimedCharacter.from_claim(no_lease), "sin lease_id en texto no vale")
	assert_false(ClaimedCharacter.from_claim(body.merged({"account": {"account_id": "1", "role": "player",
			"muted_until_unix": 0}}, true)).is_staff(), "un player no es del personal")


func test_ticket_keys_from_the_environment_format() -> void:
	var parsed: Dictionary = ZonePlatform.parse_ticket_keys("1:%s, 2:%s" % [Marshalls.raw_to_base64(_keys[1]),
			Marshalls.raw_to_base64(_keys[2])])
	assert_eq(parsed["errors"], PackedStringArray(), "dos claves")
	assert_eq((parsed["keys"] as Dictionary).keys(), [1, 2])
	assert_eq(parsed["keys"][2], _keys[2])
	var bad: Array[String] = ["0:%s" % Marshalls.raw_to_base64(_keys[1]), "1:AAAA", "1:no es base64!",
			"x", "1:%s,1:%s" % [Marshalls.raw_to_base64(_keys[1]), Marshalls.raw_to_base64(_keys[2])], ""]
	for text: String in bad:
		assert_false((ZonePlatform.parse_ticket_keys(text)["errors"] as PackedStringArray).is_empty(),
				"'%s' no vale" % text)
	var config := ServerConfig.new()
	assert_eq(ZonePlatform.env_guard_error(config, &"production", {"ticket_keys": {2: _keys[2]}}), "",
			"production sin opciones de desarrollo ni la clave de prueba")
	assert_true(ZonePlatform.env_guard_error(config, &"staging", {"ticket_keys": {1: _keys[1]}}).contains("prueba"),
			"la clave del vector fuera de test")
	assert_eq(ZonePlatform.env_guard_error(config, &"test", {"ticket_keys": {1: _keys[1]}}), "",
			"la clave del vector vale en test")
	config.debug_commands = true
	config.fake_players = 2
	var error: String = ZonePlatform.env_guard_error(config, &"production", {})
	assert_true(error.contains("no se admite") and error.contains("--debug-commands")
			and error.contains("--fake-players"), "las opciones de desarrollo en production: %s" % error)
	assert_eq(ZonePlatform.env_guard_error(config, &"dev", {}), "", "en dev valen")


## FakeZonePlatform (plataforma.md §14.1 y §14.3): guarda por personaje lo último aplicado y devuelve su pvp en la
## reclamación siguiente; cada bloque de ids sube 1024 desde next_block_first.
func test_the_fake_platform_returns_the_last_applied_pvp_and_counts_blocks() -> void:
	await _start_platform()
	var provider: TicketAuthProvider = _provider()
	_platform.add_character(42, 7, &"player", NetProtocol.Realm.VARDHEIM, {}, {"kills": 1})
	var envelope: Dictionary = {"save_format": 1, "character_id": "42", "zone_instance_id": _platform.instance_id(),
			"lease_id": "x", "seq": 1, "reason": 3, "release_lease": true, "progress": {"progress_format": 1},
			"pvp": {"kills": 5, "deaths": 2, "assists": 0, "captures": 1, "gate_damage": 300, "defend_s": 60}}
	_platform.save(42, "x", JSON.stringify(envelope).to_utf8_buffer(), true, {"seq": 1})
	await wait_process_frames(3)
	var saves: Array[PlatformEvent] = []
	for event: PlatformEvent in _platform.take_events():
		if event.kind == PlatformEvent.KIND_SAVE:
			saves.append(event)
	if assert_eq(saves.size(), 1, "el guardado vuelve"):
		assert_eq(saves[0].body_dict(), {"applied": true, "duplicate": false, "save_version": 1.0,
				"instance_status": "live"}, "200 applied con save_version 1")
	assert_eq(_platform.applied(42)["pvp"]["kills"], 5.0, "applied() da el último cuerpo aplicado")
	assert_eq(_platform.applied(43), {}, "{} sin guardados")
	assert_eq(provider.authenticate(1, _hello(42, _ticket(42, VECTOR_NOW))), AuthProvider.PENDING)
	var outcomes: Array[AuthOutcome] = await _drain(provider)
	if assert_eq(outcomes.size(), 1) and assert_not_null(outcomes[0].claimed):
		assert_eq(outcomes[0].claimed.pvp, {"kills": 5, "deaths": 2, "assists": 0, "captures": 1,
				"gate_damage": 300, "defend_s": 60}, "la reclamación siguiente trae el pvp aplicado")
	_platform.request_id_block()
	await wait_process_frames(3)
	var blocks: Array[PlatformEvent] = []
	for event: PlatformEvent in _platform.take_events():
		if event.kind == PlatformEvent.KIND_ID_BLOCK:
			blocks.append(event)
	if assert_eq(blocks.size(), 1, "un bloque"):
		assert_eq(blocks[0].body_dict(), {"first": "2049", "count": 1024.0}, "el segundo (el primero, en start)")
	assert_eq(_platform.next_block_first, 3073, "y sube 1024")
