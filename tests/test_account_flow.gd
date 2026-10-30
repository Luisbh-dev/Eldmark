extends TestCase
## Pruebas de [AccountFlow] con [member PlatformApi.request_hook] ([FakePublicPlatform]) y del bot con cuenta
## (docs/plataforma.md §5.5, §13.3 y §15 P8): iniciar sesión, crear el personaje si falta (y encontrarlo por la clave
## de su nombre), [code]enter[/code] → [ClientConfig] con billete, los reintentos de [code]character_busy[/code], y
## [OnlineMain] en modo BOT con [code]--platform[/code]: sin [code]--login[/code] o con credenciales malas sale con
## código 1 y el [code]code[/code] en el informe; con todo bien entra en una zona de verdad ([ZoneServer] con
## [FakeZonePlatform] y [TicketAuthProvider]) con el billete en el HELLO. Y [code]--bots --platform[/code] no
## arranca.

const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const REPORT_FILE: String = "test_account_flow_report.json"
const PASSWORD_FILE: String = "test_account_flow_password.txt"
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900

var _api: PlatformApi
var _platform: FakePublicPlatform
var _flow: AccountFlow
var _root: Node
var _online: OnlineMain
var _swarm: BotSwarm
var _exit_codes: Array[int] = []
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_account_hook: Callable
var _saved_swarm_hook: Callable
var _saved_swarm_config: ClientConfig
var _saved_max_fps: int = 0
# La zona de verdad con la plataforma falsa (prueba de extremo a extremo del bot).
var _server_viewport: SubViewport
var _server: ZoneServer
var _zone_platform: FakeZonePlatform
var _keys: Dictionary[int, PackedByteArray] = {}
var _port: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "AccountFlowTest"
	tree.root.add_child(_root)
	_api = PlatformApi.new()
	_root.add_child(_api)
	_platform = FakePublicPlatform.new(tree)
	_api.request_hook = _platform.hook(_api)
	_flow = AccountFlow.new(_api)
	_exit_codes.clear()
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_account_hook = OnlineMain.account_request_hook
	_saved_swarm_hook = BotSwarm.quit_hook
	_saved_swarm_config = BotSwarm.config
	_saved_max_fps = Engine.max_fps
	OnlineMain.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	BotSwarm.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	DirAccess.remove_absolute(NetHarness.build_path(REPORT_FILE))
	_keys = {2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()}


func after_each() -> void:
	for node: Node in [_online, _swarm]:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.free()
	_online = null
	_swarm = null
	if is_instance_valid(_server_viewport):
		_server_viewport.get_parent().remove_child(_server_viewport)
		_server_viewport.free()
	_server_viewport = null
	_server = null
	_zone_platform = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	_api = null
	OnlineMain.config = _saved_config
	OnlineMain.quit_hook = _saved_hook
	OnlineMain.account_request_hook = _saved_account_hook
	BotSwarm.quit_hook = _saved_swarm_hook
	BotSwarm.config = _saved_swarm_config
	Engine.max_fps = _saved_max_fps
	DirAccess.remove_absolute(NetHarness.build_path(PASSWORD_FILE))
	await wait_process_frames(2)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


# --- AccountFlow ------------------------------------------------------------------------------

func test_login_keeps_the_session_and_sends_the_normalized_email() -> void:
	var result: ApiResult = await _flow.login("  Prueba@Eldmark.TEST ", _platform.password)
	assert_true(result.ok, "%s" % result)
	var session: AccountSession = _flow.get_session()
	assert_true(session.is_active())
	assert_eq(session.access_token, "acceso-1")
	assert_eq(session.scope, "game")
	assert_eq(session.account.get("account_id"), "42")
	var body: Dictionary = _platform.calls_to("/v1/sessions")[0]["body"]
	assert_eq(body.get("email"), "prueba@eldmark.test", "sin espacios y en minúsculas")
	var bad: ApiResult = await AccountFlow.new(_api).login(_platform.email, "otra")
	assert_eq(bad.code, "invalid_credentials")
	await _flow.logout()
	assert_false(_flow.get_session().is_active(), "cerrar sesión la olvida")
	assert_eq(_platform.calls_to("/v1/sessions/current", HTTPClient.METHOD_DELETE).size(), 1)


func test_ensure_character_finds_it_by_the_key_of_its_name() -> void:
	_platform.make_character("Anéira", "solmarch", 7)
	await _flow.login(_platform.email, _platform.password)
	var result: ApiResult = await _flow.ensure_character(1, "aneira", &"")
	assert_true(result.ok, "%s" % result)
	assert_false(result.data.get("created"), "ya existía: «aneira» es «Anéira»")
	assert_eq((result.data.get("character") as Dictionary).get("name"), "Anéira")
	assert_eq(_platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST).size(), 0, "no se crea")


func test_ensure_character_creates_the_missing_one_with_the_defaults() -> void:
	_platform.make_character("Bruno", "solmarch")
	await _flow.login(_platform.email, _platform.password)
	var result: ApiResult = await _flow.ensure_character(1, "Aneira", &"")
	assert_true(result.ok, "%s" % result)
	assert_true(result.data.get("created"))
	var posted: Array[Dictionary] = _platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST)
	if not assert_eq(posted.size(), 1):
		return
	var body: Dictionary = posted[0]["body"]
	assert_eq(body.get("name"), "Aneira")
	assert_eq(body.get("realm"), "solmarch", "sin reino pedido, el de la cuenta")
	assert_eq(body.get("race_id"), "race_solmarch")
	assert_eq(body.get("starter_template_id"), "marksman", "la primera plantilla por id")
	var appearance: CharacterAppearance = CharacterAppearance.decode(AccountFlow.decode_base64(body.get("appearance")))
	assert_not_null(appearance, "8 B en base64")
	assert_true(appearance.validate(AppearanceCatalog.shared(), NetProtocol.Realm.SOLMARCH, &"race_solmarch"),
			"la apariencia por defecto del pueblo vale")


func test_ensure_character_creates_it_with_the_asked_starter_template() -> void:
	# progresion.md P8: el --loadout del bot con cuenta es la plantilla de inicio del personaje que crea.
	await _flow.login(_platform.email, _platform.password)
	await _flow.ensure_character(1, "Aneira", &"", &"squire")
	await _flow.ensure_character(1, "Bruno", &"", &"volar")
	var posted: Array[Dictionary] = _platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST)
	if not assert_eq(posted.size(), 2):
		return
	assert_eq(posted[0]["body"].get("starter_template_id"), "squire", "la pedida")
	assert_eq(posted[1]["body"].get("starter_template_id"), "marksman", "una que no existe: la primera por id")
	var found: ApiResult = await _flow.ensure_character(1, "Aneira", &"", &"marksman")
	assert_false(found.data.get("created"), "uno que ya existe no se crea otra vez")
	assert_eq(_platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST).size(), 2)


func test_ensure_character_on_a_new_account_uses_the_asked_realm_or_vardheim() -> void:
	await _flow.login(_platform.email, _platform.password)
	await _flow.ensure_character(1, "Aneira", &"solmarch")
	var first: Dictionary = _platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST)[0]["body"]
	assert_eq(first.get("realm"), "solmarch")
	_platform.characters.clear()
	_platform.account_realm = ""
	await _flow.ensure_character(1, "Bruno", &"")
	var second: Dictionary = _platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST)[1]["body"]
	assert_eq(second.get("realm"), "vardheim", "sin reino de la cuenta ni pedido, Vardheim")


func test_ensure_character_restores_a_deleted_one() -> void:
	var deleted: Dictionary = _platform.make_character("Aneira", "vardheim", 3, true)
	await _flow.login(_platform.email, _platform.password)
	var result: ApiResult = await _flow.ensure_character(1, "Aneira", &"")
	assert_true(result.ok)
	assert_true(result.data.get("restored", false), "se restaura en plazo")
	assert_eq(_platform.calls_to("/v1/characters/%s/restore" % deleted["character_id"]).size(), 1)
	assert_eq(_platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST).size(), 0)


func test_enter_gives_a_new_config_with_the_ticket() -> void:
	var character: Dictionary = _platform.make_character("Aneira", "solmarch")
	await _flow.login(_platform.email, _platform.password)
	var base := ClientConfig.new()
	base.mode = ClientConfig.Mode.TITLE
	base.loadout = "marksman"
	base.report_path = "build/x.json"
	var id: int = AccountFlow.parse_id(character["character_id"])
	var result: ApiResult = await _flow.enter(id, base)
	assert_true(result.ok, "%s" % result)
	var config: ClientConfig = result.data.get("config") as ClientConfig
	if not assert_not_null(config):
		return
	assert_eq(config.address, "127.0.0.1")
	assert_eq(config.port, 24600)
	assert_eq(config.ticket, _platform.ticket, "los 52 B del billete")
	assert_eq(config.character_id, 9007199254740993, "el id de más de 2^53, entero")
	assert_eq(config.display_name, "Aneira")
	assert_eq(config.realm, NetProtocol.Realm.SOLMARCH)
	assert_eq(config.mode, ClientConfig.Mode.ONLINE, "el título pasa a ONLINE")
	assert_eq(config.loadout, "", "con billete no se manda plantilla")
	assert_eq(config.report_path, "build/x.json", "lo demás se copia")
	assert_false(config.has_dtls(), "sin DTLS")
	assert_true(config.has_ticket())
	assert_eq(base.ticket.size(), 0, "la de partida no se toca")
	assert_eq(base.mode, ClientConfig.Mode.TITLE)
	_platform.dtls = {"cert_pem": "-----BEGIN CERTIFICATE-----\nMII…\n-----END CERTIFICATE-----", "name": "zona.eld"}
	var bot := ClientConfig.new()
	bot.mode = ClientConfig.Mode.BOT
	bot.dtls_cert_path = "viejo.pem"
	var with_dtls: ClientConfig = (await _flow.enter(id, bot)).data.get("config") as ClientConfig
	assert_eq(with_dtls.mode, ClientConfig.Mode.BOT, "un bot sigue siendo bot")
	assert_true(with_dtls.dtls_cert_pem.begins_with("-----BEGIN CERTIFICATE-----"), "el PEM de enter")
	assert_eq(with_dtls.dtls_name, "zona.eld")
	assert_eq(with_dtls.dtls_cert_path, "", "y no el de --dtls-cert")


func test_enter_retries_character_busy_until_the_character_is_free() -> void:
	var character: Dictionary = _platform.make_character("Aneira")
	await _flow.login(_platform.email, _platform.password)
	_flow.busy_retry_s = 0.05
	_platform.busy_answers = 2
	var waits: Array[int] = []
	_flow.busy_waiting.connect(func(seconds_left: int) -> void: waits.append(seconds_left))
	var result: ApiResult = await _flow.enter(AccountFlow.parse_id(character["character_id"]), ClientConfig.new())
	assert_true(result.ok, "al tercer intento entra: %s" % result)
	assert_eq(_platform.calls_to("/v1/characters/").size(), 3)
	assert_eq(waits.size(), 2, "avisa de cada espera")
	assert_true(waits[0] <= 30 and waits[0] >= 29, "con los segundos que quedan: %s" % [waits])


func test_enter_gives_up_after_the_busy_time_or_when_canceled() -> void:
	var character: Dictionary = _platform.make_character("Aneira")
	var id: int = AccountFlow.parse_id(character["character_id"])
	await _flow.login(_platform.email, _platform.password)
	_flow.busy_retry_s = 0.05
	_flow.busy_timeout_s = 0.2
	_platform.busy_answers = 1000
	var started: int = Time.get_ticks_msec()
	var result: ApiResult = await _flow.enter(id, ClientConfig.new())
	assert_eq(result.code, "character_busy", "pasado el plazo, el último character_busy")
	assert_true(Time.get_ticks_msec() - started < 1500, "sin esperar de más")
	assert_true(_platform.calls_to("/v1/characters/").size() >= 3)
	_flow.busy_timeout_s = 30.0
	_flow.busy_retry_s = 0.2
	var canceled: Array[ApiResult] = []
	var run: Callable = func() -> void: canceled.append(await _flow.enter(id, ClientConfig.new()))
	run.call()
	await wait_process_frames(2)
	_flow.cancel_enter()
	assert_true(await _wait_until(func() -> bool: return not canceled.is_empty(), 120), "cancelar corta la espera")
	assert_eq(canceled[0].code, "character_busy")


func test_enter_with_an_answer_that_is_not_understood() -> void:
	var character: Dictionary = _platform.make_character("Aneira")
	await _flow.login(_platform.email, _platform.password)
	var id: int = AccountFlow.parse_id(character["character_id"])
	var broken_bodies: Array[Dictionary] = [
		{"zone": {"host": "127.0.0.1", "port": 24600}, "character": {"character_id": "5", "name": "A",
				"realm": "vardheim"}},
		{"zone": {"host": "127.0.0.1", "port": 24600}, "ticket": "no es base64!", "character": {
				"character_id": "5", "name": "A", "realm": "vardheim"}},
		{"zone": {"host": "127.0.0.1", "port": 70000}, "ticket": "AAAA", "character": {"character_id": "5",
				"name": "A", "realm": "vardheim"}},
		{"zone": {"host": "127.0.0.1", "port": 24600}, "ticket": "AAAA", "character": {"character_id": 5,
				"name": "A", "realm": "vardheim"}},
		{"zone": {"host": "127.0.0.1", "port": 24600}, "ticket": "AAAA", "character": {"character_id": "5",
				"name": "A", "realm": "eldrun"}},
	]
	for body: Dictionary in broken_bodies:
		_platform.script_next("/v1/characters/", ApiResult.success(body))
		var result: ApiResult = await _flow.enter(id, ClientConfig.new())
		assert_eq(result.code, ApiResult.CODE_BAD_RESPONSE, "no se entiende: %s" % [body])


func test_ids_and_base64_are_read_strictly() -> void:
	assert_eq(AccountFlow.parse_id("42"), 42)
	assert_eq(AccountFlow.parse_id("9007199254740993"), 9007199254740993)
	assert_eq(AccountFlow.parse_id(42), 0, "un número sin comillas no es un id")
	assert_eq(AccountFlow.parse_id(42.0), 0)
	assert_eq(AccountFlow.parse_id("042"), 0, "sin ceros a la izquierda")
	assert_eq(AccountFlow.parse_id("-1"), 0)
	assert_eq(AccountFlow.parse_id("1e3"), 0)
	assert_eq(AccountFlow.parse_id("1234567890123456789012"), 0, "sin desbordar")
	assert_eq(AccountFlow.parse_id(""), 0)
	assert_eq(AccountFlow.decode_base64("AQID"), PackedByteArray([1, 2, 3]))
	assert_eq(AccountFlow.decode_base64("AQ=="), PackedByteArray([1]))
	assert_true(AccountFlow.decode_base64("AQ").is_empty(), "sin el relleno no vale")
	assert_true(AccountFlow.decode_base64("A*==").is_empty())
	assert_true(AccountFlow.decode_base64(null).is_empty())
	assert_eq(AccountFlow.first_starter_template(), &"marksman")
	var ids: Array[String] = []
	for template: EquipmentTemplate in AccountFlow.starter_templates():
		ids.append(String(template.id))
	assert_eq(ids, ["marksman", "squire"], "las elegibles, por id (las de starter_templates de las reglas)")
	var rules: Dictionary = ProgressionRulesExport.build()
	var exported: Array[String] = []
	for entry: Variant in rules["starter_templates"]:
		exported.append(str((entry as Dictionary).get("id")))
	assert_eq(ids, exported, "las mismas que valida la plataforma")


# --- Bot con cuenta -------------------------------------------------------------------------------

func _write_password(text: String) -> String:
	var path: String = NetHarness.build_path(PASSWORD_FILE)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return path


## Un bot con cuenta con la escena de verdad.
func _start_bot(configure: Callable = Callable()) -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.BOT
	config.platform_url = "http://127.0.0.1:24680"
	config.login = _platform.email
	config.password_file = _write_password(_platform.password + "\n")
	config.bot_seed = 3
	config.report_path = NetHarness.build_path(REPORT_FILE)
	if configure.is_valid():
		configure.call(config)
	OnlineMain.config = config
	OnlineMain.account_request_hook = func(method: int, path: String, body: Variant) -> ApiResult:
		return await (_platform.hook(_online.get_platform_api()) as Callable).call(method, path, body)
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)


func _report() -> Dictionary:
	return NetHarness.read_report(NetHarness.build_path(REPORT_FILE))


func test_a_bot_with_platform_and_without_login_ends_with_code_one() -> void:
	_start_bot(func(config: ClientConfig) -> void: config.login = "")
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 60), "cierra")
	assert_eq(_exit_codes, [1])
	var platform: Dictionary = _report().get("platform", {})
	assert_eq(platform.get("code"), "missing_login", "el code en el informe: %s" % [_report()])
	assert_true(_platform.calls.is_empty(), "sin --login no se llama a la plataforma")
	assert_null(_online.get_client(), "ni se conecta a ninguna zona")


func test_a_bot_without_a_readable_password_file_ends_with_code_one() -> void:
	_start_bot(func(config: ClientConfig) -> void: config.password_file = "res://no/existe.txt")
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 60))
	assert_eq(_exit_codes, [1])
	assert_eq((_report().get("platform", {}) as Dictionary).get("code"), "password_file")


func test_a_bot_with_bad_credentials_or_no_zone_ends_with_the_code_in_the_report() -> void:
	_start_bot(func(config: ClientConfig) -> void: config.password_file = _write_password("mala"))
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 60))
	assert_eq(_exit_codes, [1])
	var platform: Dictionary = _report().get("platform", {})
	assert_eq(platform.get("code"), "invalid_credentials")
	assert_eq(platform.get("status"), 401.0)
	assert_eq(platform.get("message"), "Correo o contraseña incorrectos")
	_online.get_parent().remove_child(_online)
	_online.free()
	_exit_codes.clear()
	_platform.script_next("/v1/characters/", ApiResult.failure(503, "zone_unavailable", "Sin zona"))
	_start_bot()
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 60))
	assert_eq(_exit_codes, [1])
	assert_eq((_report().get("platform", {}) as Dictionary).get("code"), "zone_unavailable")
	assert_eq(_platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST).size(), 1,
			"antes creó su personaje (no existía)")


func test_a_suspended_account_bot_ends_with_code_one() -> void:
	_platform.scope = "privacy"
	_platform.restriction = {"code": "account_suspended", "until": 1800000000, "reason": "Insultos"}
	_start_bot()
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 60))
	assert_eq(_exit_codes, [1])
	assert_eq((_report().get("platform", {}) as Dictionary).get("code"), "account_suspended")
	assert_eq(_platform.calls_to("/v1/worlds/").size(), 0, "con la sesión de privacidad no pide personajes")


## Extremo a extremo en el proceso: el bot inicia sesión, crea su personaje, recibe un billete firmado para la zona
## y entra con él en un ZoneServer con la plataforma falsa (reclamación incluida).
func test_a_bot_with_an_account_enters_a_zone_with_its_ticket() -> void:
	if not await _start_zone():
		return
	_platform.zone_port = _port
	var character_id: int = _platform.next_character_id
	_zone_platform.add_character(character_id, 42, &"player", NetProtocol.Realm.VARDHEIM, {}, {}, "Bot")
	_platform.ticket = _ticket(character_id, NetProtocol.Realm.VARDHEIM)
	_start_bot(func(config: ClientConfig) -> void:
		config.realm = NetProtocol.Realm.VARDHEIM
		config.character_name = "Bot"
		config.quit_after_ticks = 400)
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() != null and _online.get_client().get_state() == NetClient.State.IN_WORLD),
			"entra en el mundo con el billete")
	var claims: Array[Dictionary] = _zone_platform.sent(&"claim")
	if assert_eq(claims.size(), 1, "la zona reclamó el personaje"):
		assert_eq(claims[0].get("character_id"), str(character_id), "el del billete y el HELLO")
	assert_eq(_online.get_client().get_config().character_id, character_id)
	assert_eq(_online.get_client().get_welcome().zone_id, ZONE_ID)
	var created: Dictionary = _platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST)[0]["body"]
	assert_eq(created.get("name"), "Bot")
	assert_eq(created.get("realm"), "vardheim", "en el reino de --realm")
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty()), "termina")
	assert_eq(_exit_codes, [0], "y sale bien")
	var report: Dictionary = _report()
	assert_eq(report.get("character_id"), str(character_id))
	var platform: Dictionary = report.get("platform", {})
	assert_eq(platform.get("code"), "", "sin error de la cuenta")
	assert_eq(platform.get("created"), true)


func test_the_swarm_refuses_the_platform() -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.SWARM
	config.bot_count = 2
	config.platform_url = "http://127.0.0.1:24680"
	BotSwarm.config = config
	var packed: PackedScene = load("res://scenes/client/bot_swarm.tscn") as PackedScene
	_swarm = packed.instantiate() as BotSwarm
	tree.root.add_child(_swarm)
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 30))
	assert_eq(_exit_codes, [1], "--bots con --platform sale con código 1")
	assert_eq(_swarm.get_bots().size(), 0, "sin crear bots")


# La zona de prueba (test_world) con FakeZonePlatform y TicketAuthProvider escuchando en un puerto libre.
func _start_zone() -> bool:
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path(ZONE_ID))
	var world: Node3D = NetHarness.get_world(_server_viewport)
	var zone_root: ZoneRoot = world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	var transport := NetTransport.new()
	transport.name = "ServerTransport"
	_server_viewport.add_child(transport)
	_zone_platform = FakeZonePlatform.new()
	_zone_platform.name = "Platform"
	_zone_platform.log_sink = func(_text: String) -> void: pass
	_server_viewport.add_child(_zone_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_server_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.platform_url = "http://fake"
	_port = NetHarness.free_udp_port()
	config.port = _port
	var finished: Array = []
	_zone_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_zone_platform.start(config, {"token": "token", "ticket_keys": _keys})
	for _i: int in 120:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if not assert_eq(finished, [[true, ""]], "la plataforma falsa de la zona arranca"):
		return false
	var provider := TicketAuthProvider.new(_zone_platform, config.world_id, config.zone_id, config.channel, _keys)
	provider.log_sink = func(_text: String) -> void: pass
	if not assert_eq(_server.start(config, world, transport, provider, _zone_platform), OK,
			"el servidor abre el puerto %d" % _port):
		return false
	_zone_platform.go_live()
	return true


# Un billete válido para [param character_id] en la zona de prueba, firmado con la clave 2.
func _ticket(character_id: int, realm: int) -> PackedByteArray:
	var ticket := HandoffTicket.new()
	ticket.key_id = 2
	ticket.world_id = 1
	ticket.ticket_id = 9007199254740995
	ticket.character_id = character_id
	ticket.zone_key = HandoffTicket.zone_key_of(ZONE_ID)
	ticket.realm = realm
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = _zone_platform.now_unix()
	ticket.expires_at = ticket.issued_at + 10
	return ticket.sign(_keys[2])
