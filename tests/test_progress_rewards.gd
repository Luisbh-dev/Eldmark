extends TestCase
## Pruebas de las recompensas (docs/progresion.md §6.2 y §6.3; §15, P5c): méritos de una víctima persistente de
## otro reino con su apunte y su XP; matar a un falso o a un PNJ no da méritos; un PNJ con dos contribuyentes paga a
## los dos; dos capturas en 30 min pagan una (también tras salir y volver); los méritos de objetivo son los segundos
## en el círculo activo; un personaje marcado por un comando de GM ([member NetEntity.gm_forced], lo que harán
## [code]/gm teleport[/code] y [code]/gm visible[/code] en plataforma.md P7b) no cobra captura, méritos ni PNJ hasta
## reaparecer, y después sí; lo que provoca un comando del fuerte ([code]fort_capture_speed[/code],
## [code]fort_owner[/code] y [code]fort_kill_captain[/code]) no paga a nadie; con [code]--fake-players[/code] y
## plataforma, nada; y la subida de nivel manda LEVEL_UP solo al dueño y a su reino, pone el nivel en la entidad y es
## crítica. Sin plataforma, los efímeros cobran los PNJ en memoria y el PvP entre efímeros no da nada.
## [br][br]
## Un [ZoneServer] sin red sobre la zona plana con la fortaleza de pruebas de [FortressFixture] (captura y
## consolidación de 2 s), sin generadores de PNJ, avanzado deprisa con [FortressFixture.Stepper]; los personajes son
## peers montados a mano con su reclamación de [FakeZonePlatform] y un transporte que apunta lo que se les manda. Las
## muertes se provocan con su registro de daño ([DamageLedger]) ya escrito, como las deja el combate.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const ZONE_ID: String = "test_world"
## La hora Unix de la plataforma falsa.
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const GOLD: int = Currency.Code.GOLD
const MERITS: int = Currency.Code.MERITS
## La huella de [code]hollow[/code] (progresion.md §5.2).
const HOLLOW_REF: int = 3021413298


## Un transporte que no conecta nada y apunta lo que el servidor manda a cada peer (sin los SNAPSHOT).
class RecordingTransport:
	extends NetTransport

	## peer_id -> [bytes, …] en orden.
	var sent: Dictionary[int, Array] = {}

	func send(peer_id: int, _channel: int, bytes: PackedByteArray) -> Error:
		if NetMessages.peek_type(bytes) == NetProtocol.MSG_SNAPSHOT:
			return OK
		if not sent.has(peer_id):
			sent[peer_id] = []
		sent[peer_id].append(bytes)
		return OK


var _viewport: SubViewport = null
var _world: Node3D = null
var _server: ZoneServer = null
var _platform: FakeZonePlatform = null
var _stepper: FortressFixture.Stepper = null
var _recorder: RecordingTransport = null


func after_each() -> void:
	if is_instance_valid(_stepper):
		_stepper.get_parent().remove_child(_stepper)
		_stepper.free()
	if is_instance_valid(_server):
		_server._transport = null
		_server.get_parent().remove_child(_server)
		_server.free()
	if is_instance_valid(_recorder):
		_recorder.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_stepper = null
	_server = null
	_recorder = null
	_platform = null
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Montaje ----------------------------------------------------------------------------------

## La zona plana con la fortaleza de pruebas y el servidor sin red. Con [param with_platform], la plataforma falsa
## con el reloj en [constant NOW], ya arrancada y viva, y el primer bloque de ids recibido; [param fake_players] es
## el [code]--fake-players[/code] de la configuración (el servidor no los crea: eso lo hace [ServerMain]).
func _start(with_platform: bool, fake_players: int = 0) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	config.no_npcs = true
	config.fake_players = fake_players
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_viewport.add_child(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var provider: AuthProvider = DevAuthProvider.new()
	if with_platform:
		var finished: Array = []
		_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
		_platform.start(config, {"token": "token", "ticket_keys": keys})
		for _i: int in 120:
			if not finished.is_empty():
				break
			await wait_process_frames()
		if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "el servidor arranca"):
		return false
	_progress().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	if with_platform:
		_platform.go_live()
		var ready: bool = await _advance_until(func() -> bool: return _progress().get_ids().available() > 0)
		if not assert_true(ready, "llega el primer bloque de ids"):
			return false
	return true


func _progress() -> ProgressService:
	return _server.get_progress()


func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


## Avanza de 2 en 2 ticks (con fotogramas entre medias para las respuestas de la plataforma) hasta que se cumpla
## [param condition] o pasen [param max_ticks].
func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


## Da de alta en la plataforma falsa al personaje [param character_id] de [param realm] y lo hace entrar con el
## peer [param peer_id] como el alta de verdad (reclamación, [method ProgressService.prepare], LOADING y
## CLIENT_READY). Devuelve el peer, ya en el mundo.
func _join(peer_id: int, character_id: int, realm: int) -> ServerPeer:
	_platform.add_character(character_id, character_id * 10, &"player", realm, {})
	return await _enter(peer_id, _claim(character_id))


## Monta un peer como el alta de verdad con [param claimed] (con plataforma) o efímero de [param realm] (sin ella)
## y espera su alta.
func _enter(peer_id: int, claimed: ClaimedCharacter, realm: int = VARDHEIM) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm if claimed != null else realm
	peer.display_name = claimed.display_name if claimed != null else "Prueba%d" % peer_id
	peer.loading_since_tick = _server.get_tick()
	_server._peers[peer_id] = peer
	if claimed != null:
		peer.claimed = claimed
		assert_true(_progress().prepare(peer_id, claimed), "se prepara el registro")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "el peer %d entra en el mundo" % peer_id)
	return peer


## La reclamación siguiente de [param character_id] en la plataforma falsa, con la ida y vuelta por JSON.
func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	return ClaimedCharacter.from_claim(JSON.parse_string(JSON.stringify(answer[1])))


## Sale [param peer] (como un CLIENT_LEAVE) y espera a que la plataforma conteste su guardado final.
func _leave(peer: ServerPeer) -> void:
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	_server._mark_leaving(peer)
	await _advance(1)
	await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
				and _server.get_saver().pending_count() == 0)
	_server._peers.erase(peer.peer_id)


## Mata a [param victim] en el tick actual con el registro de daño [param damage] ({atacante: daño}) ya escrito y
## [param killer] como autor (0 = el entorno): DEATH y, con autor, KILL con los asistentes del registro, como en el
## combate.
func _kill(victim: int, killer: int, damage: Dictionary) -> void:
	var combatant: Combatant = _server.get_combat().get_combatant(victim)
	var tick: int = _server.get_tick()
	for attacker: int in damage:
		combatant.ledger.record(tick, attacker, int(damage[attacker]))
	_server.get_combat()._die(combatant, tick, killer, 0)


## Un PNJ de la definición [param id] (de los Huecos) quieto en [param position].
func _npc(id: StringName, position: Vector3 = Vector3(0.0, 0.0, 10.0)) -> int:
	var definition: NpcDefinition = NpcCatalog.get_definition(id)
	return _server.add_npc(NpcBrain.new(NpcBrain.Mode.STILL), definition.display_name, RealmCatalog.NEUTRAL_CODE,
			position, 0.0, false, definition)


## Un jugador falso quieto de [param realm] en [param position].
func _fake(realm: int, position: Vector3 = Vector3(0.0, 0.0, -10.0)) -> int:
	var net_id: int = _server.add_fake_player(CombatFixture.ScriptBrain.new(1), realm)
	_server.teleport(net_id, position)
	return net_id


func _player(peer: ServerPeer) -> PlayerProgress:
	return _progress().get_player(peer.entity.net_id)


func _wallet(peer: ServerPeer, currency: int) -> int:
	return _player(peer).record.wallets[currency]


func _xp(peer: ServerPeer) -> int:
	return _player(peer).record.xp_total


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


## El capitán cae en combate a manos de [param realm] y espera a que [param realm] capture con quien esté en el
## círculo (y, con [param garrison], a que llegue su guarnición). Avanza de 6 en 6 ticks sin esperar a la plataforma.
func _capture(realm: int, garrison: bool = true) -> bool:
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), realm), "el capitán cae")
	var captured: bool = await _advance_fast_until(func() -> bool: return _state().owner == realm, 400)
	if not captured:
		return false
	if garrison:
		return await _advance_fast_until(func() -> bool:
			return _state().phase == FortressState.Phase.GARRISONED, 400)
	return true


## Avanza de 6 en 6 ticks (un fotograma de física cada vez) hasta que se cumpla [param condition] o pasen
## [param max_ticks].
func _advance_fast_until(condition: Callable, max_ticks: int) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks and not condition.call():
		await _advance(6)
		elapsed += 6
	return bool(condition.call())


## Los mensajes de [param type] mandados a [param peer_id].
func _messages(peer_id: int, type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _recorder.sent.get(peer_id, []):
		if NetMessages.peek_type(bytes) == type:
			found.append(bytes)
	return found


## Los LEVEL_UP mandados a [param peer_id].
func _level_ups(peer_id: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for bytes: PackedByteArray in _messages(peer_id, NetProtocol.MSG_ENTITY_EVENT):
		var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
		if event != null and event.event == NetMessages.EntityEvent.Kind.LEVEL_UP:
			found.append(event)
	return found


## Los apuntes de las operaciones de la sección [code]progress[/code] del último guardado aplicado de
## [param character_id], con su [code]kind[/code]: [code][{kind, currency, delta, reason, ref_kind, ref_id}][/code].
func _saved_entries(character_id: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var progress: Dictionary = _platform.applied(character_id).get("progress", {})
	for op: Dictionary in progress.get("ops", []):
		for entry: Dictionary in op.get("ledger", []):
			entries.append({"kind": int(op["kind"]), "currency": int(entry["currency"]),
					"delta": int(entry["delta"]), "reason": int(entry["reason"]),
					"ref_kind": int(entry["ref_kind"]), "ref_id": String(entry["ref_id"])})
	return entries


## Muere [param net_id] (consola) y reaparece en cuanto puede (las oleadas son de 10 s en una zona con fortaleza).
func _die_and_respawn(net_id: int) -> void:
	_server.console_command("kill %d" % net_id)
	await _advance(2)
	var combatant: Combatant = _server.get_combat().get_combatant(net_id)
	await _advance(maxi(combatant.respawn_tick - _server.get_tick() - 6, 0))
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED, "pide reaparecer")
	await _advance(10)
	assert_true(combatant.is_alive(), "ha reaparecido")


# --- Datos ------------------------------------------------------------------------------------

func test_npc_rewards_are_the_design_values_and_contributors_need_ten_percent() -> void:
	var expected: Dictionary = {
		&"hollow": [40, 2], &"realm_guard": [60, 3], &"ford_captain": [400, 50], &"realm_captain": [400, 50],
		&"gate_guardian": [0, 0],
	}
	for id: StringName in expected:
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		if assert_not_null(definition, "%s existe" % id):
			assert_eq([definition.xp_reward, definition.gold_reward], expected[id], "%s: XP y oro de §6.2" % id)
	assert_eq(NpcCatalog.get_errors(), PackedStringArray(), "el catálogo de PNJ no tiene errores")
	assert_eq(HandoffTicket.zone_key_of("hollow"), HOLLOW_REF, "la huella de hollow (§5.2)")
	var ledger := DamageLedger.new(99)
	ledger.record(10, 7, 1500)
	ledger.record(20, 3, 900)
	ledger.record(30, 5, 100)
	ledger.record(40, 99, 500)
	assert_eq(ledger.contributors(40), PackedInt32Array([3, 7]), "≥ 10 % del daño, por id; la víctima no cuenta")
	assert_eq(ledger.contributors(10 + DamageLedger.WINDOW_TICKS), PackedInt32Array([3, 5]),
			"solo la ventana de 900 ticks (el de 1500 ya no está)")
	assert_eq(DamageLedger.new(1).contributors(0), PackedInt32Array(), "sin daño, nadie")


# --- PvP y PNJ ------------------------------------------------------------------------------------

func test_merits_of_a_persistent_enemy_victim_give_a_ledger_entry_and_xp() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM)
	var bruno: ServerPeer = await _join(2, 102, SOLMARCH)
	var cai: ServerPeer = await _join(3, 103, VARDHEIM)
	if ana == null or ana.entity == null or bruno.entity == null or cai.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	var cai_id: int = cai.entity.net_id
	_kill(bruno.entity.net_id, ana_id, {ana_id: 700, cai_id: 300})
	assert_eq([_wallet(ana, MERITS), _player(ana).record.realm_points, _xp(ana)], [10, 10, 100],
			"la baja: 10 méritos, 10 puntos de reino y 100 de XP")
	assert_eq([_wallet(cai, MERITS), _player(cai).record.realm_points, _xp(cai)], [5, 5, 50],
			"la asistencia: 5 méritos y 50 de XP")
	assert_eq(_wallet(ana, GOLD), 0, "el PvP no da oro")
	assert_eq([_wallet(bruno, MERITS), _xp(bruno)], [0, 0], "la víctima, nada")
	# Al dueño: WALLET_UPDATE de los méritos con su motivo y PROGRESS_UPDATE con lo ganado (agrupados por flush).
	await _advance(12)
	var wallet: ProgressMessages.WalletUpdate = null
	for bytes: PackedByteArray in _messages(1, NetProtocol.MSG_WALLET_UPDATE):
		var update: ProgressMessages.WalletUpdate = ProgressMessages.WalletUpdate.decode(bytes)
		if update != null and update.currency == MERITS and update.delta != 0:
			wallet = update
	if assert_not_null(wallet, "llega el WALLET_UPDATE de los méritos"):
		assert_eq([wallet.balance, wallet.delta, wallet.reason], [10, 10, EconomyReason.PVP_KILL])
	var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(
			_messages(1, NetProtocol.MSG_PROGRESS_UPDATE)[-1])
	assert_eq([progress.gained, progress.source, progress.realm_points], [100, ProgressMessages.XpSource.PVP, 10],
			"el PROGRESS_UPDATE de la baja")
	# Un falso de otro reino y un PNJ no dan méritos (el PNJ sí su XP y su oro).
	var fake: int = _fake(SOLMARCH)
	_kill(fake, ana_id, {ana_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [10, 100], "matar a un falso no da nada")
	var hollow: int = _npc(&"hollow")
	_kill(hollow, ana_id, {ana_id: 2500})
	assert_eq([_wallet(ana, MERITS), _xp(ana), _wallet(ana, GOLD)], [10, 140, 2],
			"un PNJ: 40 de XP y 2 de oro, sin méritos")
	# El guardado lleva los apuntes agregados en una GAMEPLAY, con sus referencias.
	await _leave(ana)
	var entries: Array[Dictionary] = _saved_entries(101)
	assert_true(entries.has({"kind": EconomyOp.Kind.GAMEPLAY, "currency": MERITS, "delta": 10,
			"reason": EconomyReason.PVP_KILL, "ref_kind": LedgerEntry.RefKind.CHARACTER, "ref_id": "102"}),
			"el apunte de la baja con la víctima (%s)" % [entries])
	assert_true(entries.has({"kind": EconomyOp.Kind.GAMEPLAY, "currency": GOLD, "delta": 2,
			"reason": EconomyReason.NPC_KILL, "ref_kind": LedgerEntry.RefKind.NPC, "ref_id": str(HOLLOW_REF)}),
			"el oro del Hueco con su huella")
	var saved: Dictionary = _platform.applied(101).get("progress", {})
	assert_eq([int(saved.get("xp_total", -1)), int(saved.get("realm_points", -1))], [140, 10], "la foto")


func test_an_npc_with_two_contributors_pays_both_and_not_the_one_under_ten_percent() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 111, VARDHEIM)
	var cai: ServerPeer = await _join(2, 113, VARDHEIM)
	var dani: ServerPeer = await _join(3, 114, SOLMARCH)
	if ana == null or ana.entity == null or cai.entity == null or dani.entity == null:
		return
	var hollow: int = _npc(&"hollow")
	# Ana da el golpe de gracia con el 60 %, Cai hace el 36 % y Dani el 4 %.
	_kill(hollow, ana.entity.net_id, {ana.entity.net_id: 1500, cai.entity.net_id: 900, dani.entity.net_id: 100})
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [40, 2], "el que lo remata cobra entero")
	assert_eq([_xp(cai), _wallet(cai, GOLD)], [40, 2], "el otro contribuyente, también entero")
	assert_eq([_xp(dani), _wallet(dani, GOLD)], [0, 0], "con menos del 10 %, nada")
	assert_eq([_wallet(ana, MERITS), _wallet(cai, MERITS)], [0, 0], "sin méritos")
	# Un PNJ que muere por el entorno con daño de un jugador en la ventana también le paga (sin KILL).
	var guard: int = _npc(&"realm_guard")
	_kill(guard, 0, {cai.entity.net_id: 800})
	assert_eq([_xp(cai), _wallet(cai, GOLD)], [100, 5], "el guardia: 60 de XP y 3 de oro")
	assert_eq(_progress().get_stats()["npc_rewards"], 3, "tres cobros")


func test_without_platform_ephemerals_collect_npcs_in_memory_and_pvp_gives_nothing() -> void:
	if not await _start(false):
		return
	var ana: ServerPeer = await _enter(1, null, VARDHEIM)
	var bruno: ServerPeer = await _enter(2, null, SOLMARCH)
	if ana == null or ana.entity == null or bruno.entity == null:
		return
	assert_false(_player(ana).persistent, "sin plataforma, efímero")
	_kill(bruno.entity.net_id, ana.entity.net_id, {ana.entity.net_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [0, 0], "la víctima efímera no da méritos ni XP")
	var hollow: int = _npc(&"hollow")
	_kill(hollow, ana.entity.net_id, {ana.entity.net_id: 2500})
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [40, 2], "el PNJ paga en memoria")
	await _advance(12)
	var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(
			_messages(1, NetProtocol.MSG_PROGRESS_UPDATE)[-1])
	assert_eq([progress.gained, progress.source], [40, ProgressMessages.XpSource.NPC], "y lo dice al dueño")


# --- Capturas y objetivo -----------------------------------------------------------------------------

func test_two_captures_in_thirty_minutes_pay_one_and_objective_merits_are_circle_seconds() -> void:
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 121, VARDHEIM)
	var sol: ServerPeer = await _join(2, 122, SOLMARCH)
	if ana == null or ana.entity == null or sol.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	_server.teleport(ana_id, circle)
	_server.teleport(sol.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	if not assert_true(await _capture(VARDHEIM), "Vardheim captura"):
		return
	var scores: ScoreKeeper = _server.get_scores()
	var merits: int = _wallet(ana, MERITS)
	assert_eq(scores.get_entry(ana_id).captures, 1)
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "20 de oro de la captura")
	assert_true(merits >= 2, "méritos de objetivo por los segundos en el círculo activo (%d)" % merits)
	@warning_ignore("integer_division")
	assert_eq(merits, scores.get_entry(ana_id).circle_ticks / 60, "uno por segundo entero en el círculo activo")
	assert_eq(_player(ana).record.realm_points, merits, "los de objetivo suben los puntos de reino")
	assert_eq(_xp(ana), ProgressService.CAPTURE_XP + 10 * merits, "300 de XP de la captura y 10 por mérito")
	var key: String = ProgressService.TIMER_CAPTURE_PREFIX + String(FORTRESS)
	assert_eq(_player(ana).record.timers.get(key, 0), NOW + ProgressService.CAPTURE_COOLDOWN_S,
			"el temporizador capture:<id> vence a los 30 min")
	assert_eq(_server.get_saver().get_stats()["criticals_by_reason"].get("capture", 0), 1, "cobrar es crítico")
	# Solmarch la quita y Vardheim la recupera antes de 30 min: la segunda no paga.
	_server.teleport(ana_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.teleport(sol.entity.net_id, circle)
	if not assert_true(await _capture(SOLMARCH), "Solmarch la quita"):
		return
	assert_eq(_wallet(sol, GOLD), ProgressService.CAPTURE_GOLD, "Solmarch cobra la suya")
	_server.teleport(sol.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.teleport(ana_id, circle)
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim la recupera"):
		return
	assert_eq(scores.get_entry(ana_id).captures, 2, "la captura cuenta en el marcador")
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "pero dos capturas en 30 min pagan una")
	assert_eq(_progress().get_stats()["captures_on_cooldown"], 1)
	assert_eq(_xp(ana), ProgressService.CAPTURE_XP + 10 * _wallet(ana, MERITS), "solo los méritos de objetivo")
	# Sale y vuelve a los 10 min: el temporizador vuelve con él.
	await _leave(ana)
	_platform.fake_now_unix = NOW + 600
	ana = await _enter(3, _claim(121))
	if ana == null or ana.entity == null:
		return
	assert_eq(_player(ana).record.timers.get(key, 0), NOW + ProgressService.CAPTURE_COOLDOWN_S, "guardado")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "a los 10 min sigue sin pagar")
	# Pasados los 30 min vuelve a pagar.
	await _leave(ana)
	_platform.fake_now_unix = NOW + ProgressService.CAPTURE_COOLDOWN_S + 1
	ana = await _enter(4, _claim(121))
	if ana == null or ana.entity == null:
		return
	assert_false(_player(ana).record.timers.has(key), "el vencido no vuelve")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), 2 * ProgressService.CAPTURE_GOLD, "pasados 30 min, paga")
	assert_eq(_player(ana).record.timers.get(key, 0), NOW + 2 * ProgressService.CAPTURE_COOLDOWN_S + 1,
			"y vuelve a contar")
	# Otro reino en la lista (no pasa: la lista es del captor) no cobra, aunque no tenga temporizador de esa fortaleza.
	var sol_gold: int = _wallet(sol, GOLD)
	_progress().on_capture(&"otro_fuerte", VARDHEIM, PackedInt32Array([sol.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(sol, GOLD), sol_gold, "solo cobra el reino captor")
	_progress().on_capture(&"otro_fuerte", SOLMARCH, PackedInt32Array([sol.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(sol, GOLD), sol_gold + ProgressService.CAPTURE_GOLD, "el temporizador es por fortaleza")


# --- Marcas de GM y cambios forzados ---------------------------------------------------------------

func test_a_gm_forced_character_collects_nothing_until_it_respawns() -> void:
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 131, VARDHEIM)
	var cai: ServerPeer = await _join(2, 133, VARDHEIM)
	var bruno: ServerPeer = await _join(3, 132, SOLMARCH)
	var berta: ServerPeer = await _join(4, 134, SOLMARCH)
	if ana == null or ana.entity == null or cai.entity == null or bruno.entity == null or berta.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	var cai_id: int = cai.entity.net_id
	# Lo que harán /gm teleport y /gm visible (plataforma.md P7b): llevarla al círculo y marcarla.
	_server.teleport(ana_id, circle)
	ana.entity.gm_forced = true
	_server.teleport(cai_id, circle + Vector3(1.0, 0.0, 0.0))
	_server.teleport(bruno.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.teleport(berta.entity.net_id, circle + Vector3(30.0, 0.0, 2.0))
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captura"):
		return
	assert_eq(_wallet(cai, GOLD), ProgressService.CAPTURE_GOLD, "Cai cobra la captura")
	assert_true(_wallet(cai, MERITS) > 0, "y méritos de objetivo")
	assert_eq([_wallet(ana, GOLD), _wallet(ana, MERITS), _xp(ana)], [0, 0, 0],
			"la marcada no cobra la captura ni los méritos de objetivo")
	_kill(bruno.entity.net_id, ana_id, {ana_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [0, 0], "ni los de una baja")
	var hollow: int = _npc(&"hollow")
	_kill(hollow, ana_id, {ana_id: 2000, cai_id: 500})
	assert_eq([_wallet(ana, GOLD), _xp(ana)], [0, 0], "ni un PNJ")
	assert_eq(_wallet(cai, GOLD), ProgressService.CAPTURE_GOLD + 2, "el otro contribuyente sí")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), 0, "aunque llegara en la lista")
	# Al reaparecer, la marca se va y vuelve a cobrar.
	await _die_and_respawn(ana_id)
	assert_false(ana.entity.gm_forced, "la reaparición quita la marca")
	_kill(berta.entity.net_id, ana_id, {ana_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [10, 100], "ya cobra una baja")
	var second: int = _npc(&"hollow", Vector3(0.0, 0.0, 14.0))
	_kill(second, ana_id, {ana_id: 2500})
	assert_eq([_wallet(ana, GOLD), _xp(ana)], [2, 140], "y un PNJ")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), 2 + ProgressService.CAPTURE_GOLD, "y una captura")


func test_fort_commands_pay_nobody_and_a_real_captain_kill_does() -> void:
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 141, VARDHEIM)
	if ana == null or ana.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	var fortresses: FortressController = _server.get_fortresses()
	# El capitán muerto en combate es un cambio de verdad: paga a quien lo mató.
	var captain: int = _npc(&"ford_captain", circle + Vector3(4.0, 0.0, 4.0))
	fortresses.register_captain(FORTRESS, captain)
	_kill(captain, ana_id, {ana_id: 30000})
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [400, 50], "el capitán de verdad: 400 de XP y 50 de oro")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	# fort_reset y fort_kill_captain: el capitán muerto por el comando no paga, ni a quien le hizo daño.
	_server.console_command("fort_reset")
	await _advance(2)
	var second: int = _npc(&"ford_captain", circle + Vector3(4.0, 0.0, -4.0))
	fortresses.register_captain(FORTRESS, second)
	_server.get_combat().get_combatant(second).ledger.record(_server.get_tick(), ana_id, 20000)
	_server.console_command("fort_kill_captain")
	await _advance(2)
	assert_true(_server.get_combat().get_combatant(second).is_dead(), "el comando lo mata")
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [400, 50], "su muerte no paga")
	# La captura que sigue a fort_kill_captain es forzada: ni captura ni méritos de objetivo.
	_server.teleport(ana_id, circle)
	await _advance_fast_until(func() -> bool: return _state().owner == VARDHEIM, 400)
	assert_eq(_state().owner, VARDHEIM, "Vardheim captura tras el comando")
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [400, 50, 0], "sin cobrar nada")
	# fort_owner tampoco.
	_server.console_command("fort_owner solmarch")
	await _advance(12)
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [400, 50, 0], "fort_owner no paga")
	# Con fort_capture_speed ≠ 1, aunque el capitán caiga en combate, la captura es forzada.
	await _advance_fast_until(func() -> bool: return _state().phase == FortressState.Phase.GARRISONED, 400)
	_server.console_command("fort_capture_speed 20")
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captura a x20"):
		return
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [400, 50, 0], "fort_capture_speed no paga")
	assert_eq(_progress().get_stats()["captures_paid"], 0, "ninguna captura pagada")


func test_fake_players_with_the_platform_pay_nothing_and_say_so() -> void:
	if not await _start(true, 2):
		return
	assert_true(_progress().rewards_blocked(), "--fake-players con plataforma: sin recompensas")
	var lines: Array[String] = []
	var probe := ProgressService.new()
	probe.log_sink = func(text: String) -> void: lines.append(text)
	probe.setup(_server, _platform, null, null)
	assert_true(lines.has(ProgressService.FAKE_PLAYERS_TEXT), "y lo dice en el registro al arrancar")
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 151, VARDHEIM)
	var bruno: ServerPeer = await _join(2, 152, SOLMARCH)
	if ana == null or ana.entity == null or bruno.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	_kill(bruno.entity.net_id, ana_id, {ana_id: 1000})
	_kill(_npc(&"hollow"), ana_id, {ana_id: 2500})
	_server.teleport(ana_id, circle)
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captura"):
		return
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [0, 0, 0], "nada de nada")
	assert_eq(_server.get_scores().get_entry(ana_id).captures, 1, "el marcador sí cuenta")


# --- Subida de nivel ----------------------------------------------------------------------------------

func test_a_level_up_goes_to_the_owner_and_its_realm_only_and_is_critical() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 161, VARDHEIM)
	var cai: ServerPeer = await _join(2, 163, VARDHEIM)
	var sol: ServerPeer = await _join(3, 162, SOLMARCH)
	if ana == null or ana.entity == null or cai.entity == null or sol.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	# Todos se ven (la política de interés por defecto): el aliado y el enemigo tienen a Ana relevante.
	await _advance(12)
	assert_true(cai.relevant.get(ana_id, false) and sol.relevant.get(ana_id, false), "los dos ven a Ana")
	var criticals_before: int = _server.get_saver().get_stats()["criticals_by_reason"].get("level_up", 0)
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	# 400 del capitán no llegan a 500; con 300 de una captura sube al 2.
	_kill(_npc(&"ford_captain"), ana_id, {ana_id: 30000})
	assert_eq(_player(ana).record.level, 1, "400 de XP: nivel 1")
	assert_eq(_level_ups(1), [] as Array[NetMessages.EntityEvent], "sin subir no hay LEVEL_UP")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana_id]), _server.get_tick())
	assert_eq([_player(ana).record.level, _xp(ana)], [2, 700], "700 de XP: nivel 2")
	assert_eq(ana.entity.level, 2, "el nivel en la entidad, para los SPAWN siguientes")
	for peer_id: int in [1, 2]:
		var events: Array[NetMessages.EntityEvent] = _level_ups(peer_id)
		if assert_eq(events.size(), 1, "un LEVEL_UP al peer %d" % peer_id):
			assert_eq([events[0].net_id, events[0].level], [ana_id, 2])
	assert_eq(_level_ups(3).size(), 0, "al enemigo no le llega")
	assert_eq(_server.get_saver().get_stats()["criticals_by_reason"].get("level_up", 0), criticals_before + 1,
			"subir de nivel es crítico")
	var saved: bool = await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
				and int(_platform.applied(161).get("progress", {}).get("level", 0)) == 2, 60)
	assert_true(saved, "el guardado crítico sale enseguida con el nivel 2")
	await _advance(12)
	var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(
			_messages(1, NetProtocol.MSG_PROGRESS_UPDATE)[-1])
	assert_eq([progress.level, progress.xp_in_level, progress.gained], [2, 200, 700],
			"el PROGRESS_UPDATE con el nivel nuevo y lo ganado")
	# Un SPAWN de Ana hacia su reino lleva el 2; hacia el enemigo, 0.
	var to_ally: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(ana.entity.encode_spawn(_server.get_tick(),
			false, VARDHEIM))
	var to_enemy: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(ana.entity.encode_spawn(
			_server.get_tick(), false, SOLMARCH))
	assert_eq([to_ally.level, to_enemy.level], [2, 0], "el nivel solo hacia su reino")
