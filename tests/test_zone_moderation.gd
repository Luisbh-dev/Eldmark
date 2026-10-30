extends TestCase
## Pruebas de la moderación en la zona (docs/plataforma.md §9 y §15, P7b): sin rol, «Comando desconocido»; un
## DEBUG_COMMAND sin rol, aviso y nada; [code]/gm silenciar[/code] de un jugador y de un moderador; el silencio con su
## tiempo restante, de la sanción y del latido; la entrada de auditoría con la cuenta del GM y [code]source[/code]
## [code]zone[/code]; [code]/gm teleport[/code] y [code]/gm visible[/code] marcan con [code]gm_forced[/code] y la
## reaparición lo quita; el GM invisible fuera del interés, del círculo y del marcador; un ignorado no susurra, no
## invita ni llega a su canal de zona; el reporte con su prueba y su límite; el renombrado forzado; la expulsión de un
## moderador; los avisos al entrar; el lote de chat; y salir y volver no rellena las ráfagas.
## [br][br]
## Un [ZoneServer] sin red sobre la zona plana con la fortaleza de pruebas, con [FakeZonePlatform] (el reloj fijo y el
## latido a mano) y peers montados a mano con su reclamación, como test_progress_rewards.gd; lo que llega a cada peer
## lo apunta un transporte falso, y los mensajes de los clientes entran por [code]_on_packet_received[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const UNKNOWN: String = "Comando desconocido. Escribe /ayuda."


## Un transporte que no conecta nada y apunta lo que el servidor manda a cada peer (sin los SNAPSHOT).
class RecordingTransport:
	extends NetTransport

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

## La zona plana con la fortaleza de pruebas y el servidor sin red; con [param with_platform], la plataforma falsa
## arrancada y viva, con el reloj en [constant NOW] y sin latidos solos (se mandan a mano).
func _start(with_platform: bool, debug_commands: bool = false) -> bool:
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
	config.debug_commands = debug_commands
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_platform.fake_heartbeat_s = 600.0
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
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_server.get_moderation().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	if with_platform:
		_platform.go_live()
		var ready: bool = await _advance_until(func() -> bool:
			return _server.get_progress().get_ids().available() > 0)
		if not assert_true(ready, "llega el primer bloque de ids"):
			return false
	return true


func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


## El personaje [param character_id] (cuenta [code]character_id × 10[/code], [param role]) entra con el peer
## [param peer_id]. Devuelve el peer, ya en el mundo.
func _join(peer_id: int, character_id: int, realm: int, display_name: String,
		role: StringName = &"player") -> ServerPeer:
	_platform.add_character(character_id, character_id * 10, role, realm, {}, {}, display_name)
	return await _enter(peer_id, _claim(character_id))


func _enter(peer_id: int, claimed: ClaimedCharacter, realm: int = VARDHEIM, display_name: String = "") -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm if claimed != null else realm
	peer.display_name = claimed.display_name if claimed != null else display_name
	peer.loading_since_tick = _server.get_tick()
	peer.remote_address = "127.0.0.1"
	_server._peers[peer_id] = peer
	if claimed != null:
		peer.claimed = claimed
		assert_true(_server.get_progress().prepare(peer_id, claimed), "se prepara el registro")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "el peer %d entra en el mundo" % peer_id)
	return peer


func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	return ClaimedCharacter.from_claim(JSON.parse_string(JSON.stringify(answer[1])))


## Lo que manda el cliente de [param peer] (un CHAT_SEND, un DEBUG_COMMAND…), tal como llega del transporte.
func _receive(peer: ServerPeer, bytes: PackedByteArray) -> void:
	_server._on_packet_received(peer.peer_id, bytes)


func _chat(peer: ServerPeer, channel: int, text: String, recipient: String = "") -> void:
	var message := NetMessages.ChatSend.new()
	message.channel = channel
	message.recipient = recipient
	message.text = text
	_receive(peer, message.encode())


## Una línea de comando (lo que manda el cliente por el canal GM, sin la barra).
func _command(peer: ServerPeer, line: String) -> void:
	_chat(peer, ChatChannel.Id.GM, line)


func _messages(peer: ServerPeer, type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _recorder.sent.get(peer.peer_id, []):
		if NetMessages.peek_type(bytes) == type:
			found.append(bytes)
	return found


func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for bytes: PackedByteArray in _messages(peer, NetProtocol.MSG_CHAT_MESSAGE):
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null and message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _last_system(peer: ServerPeer) -> String:
	var texts: PackedStringArray = _system_texts(peer)
	return texts[texts.size() - 1] if not texts.is_empty() else ""


func _chat_lines(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for bytes: PackedByteArray in _messages(peer, NetProtocol.MSG_CHAT_MESSAGE):
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null and message.channel != ChatChannel.Id.SYSTEM:
			texts.append("%s: %s" % [message.sender, message.text])
	return texts


func _notices(peer: ServerPeer) -> Array[NetMessages.Notice]:
	var found: Array[NetMessages.Notice] = []
	for bytes: PackedByteArray in _messages(peer, NetProtocol.MSG_NOTICE):
		found.append(NetMessages.Notice.decode(bytes))
	return found


## Espera a que [param peer] reciba un texto del sistema nuevo (tras [param before]).
func _await_reply(peer: ServerPeer, before: int) -> String:
	await _advance_until(func() -> bool: return _system_texts(peer).size() > before, 300)
	return _last_system(peer)


## Las entradas del lote [param kind] (su lista se llama [param field] en el cuerpo), mandadas y en cola, con la ida y
## vuelta por JSON (los números, en coma flotante, como los lee la plataforma falsa).
func _batch_entries(kind: StringName, field: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for batch: Dictionary in _platform.sent(kind):
		for entry: Dictionary in batch.get(field, []):
			entries.append(entry)
	for entry: Dictionary in _platform.queued(kind):
		entries.append(_json(entry))
	return entries


func _audit_entries() -> Array[Dictionary]:
	return _batch_entries(&"audit", "entries")


## [param value] tras la ida y vuelta por JSON, para comparar con lo que recibe la plataforma falsa.
static func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))


func _entries_of(command: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for entry: Dictionary in _audit_entries():
		if entry.get("command") == command:
			found.append(entry)
	return found


func _die_and_respawn(net_id: int) -> void:
	_server.console_command("kill %d" % net_id)
	await _advance(2)
	var combatant: Combatant = _server.get_combat().get_combatant(net_id)
	await _advance(maxi(combatant.respawn_tick - _server.get_tick() - 6, 0))
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED, "pide reaparecer")
	await _advance(10)
	assert_true(combatant.is_alive(), "ha reaparecido")


# --- /gm y el rol ---------------------------------------------------------------------------------

func test_gm_needs_its_role_a_moderator_mutes_and_the_audit_says_who() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var mod: ServerPeer = await _join(2, 102, VARDHEIM, "Moira", &"moderator")
	var bruno: ServerPeer = await _join(3, 103, VARDHEIM, "Bruno")
	if ana == null or mod == null or bruno == null or bruno.entity == null:
		return
	# Sin rol: lo mismo que un comando que no existe, y nada sale hacia la plataforma.
	for line: String in ["gm silenciar Bruno 30 insultos", "gm ayuda", "gm", "gm volar", "xyz Bruno"]:
		_command(ana, line)
		await _advance(1)
		assert_eq(_last_system(ana), UNKNOWN, "«%s» de un jugador" % line)
	assert_eq(_platform.sent(PlatformEvent.KIND_SANCTION).size(), 0, "ninguna sanción pedida")
	# Un moderador no tiene los de gm, y la ayuda solo le enseña los suyos.
	_command(mod, "gm suspender Bruno 1d spam")
	await _advance(1)
	assert_eq(_last_system(mod), UNKNOWN, "suspender es de gm")
	_command(mod, "gm ayuda")
	await _advance(1)
	var help: String = _last_system(mod)
	assert_true(help.contains("silenciar") and help.contains("aviso") and help.contains("expulsar"), help)
	assert_false(help.contains("teleport") or help.contains("suspender") or help.contains("banear"), help)
	# El moderador silencia: la plataforma lo autoriza y se aplica ya.
	var before: int = _system_texts(mod).size()
	_command(mod, "gm Silenciar bruno 30 insultos repetidos")
	var reply: String = await _await_reply(mod, before)
	var requests: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_SANCTION)
	if not assert_eq(requests.size(), 1, "una sanción pedida"):
		return
	assert_eq(requests[0], _json({"zone_instance_id": _platform.instance_id(), "author_character_id": "102",
			"target_name": "bruno", "kind": "mute", "minutes": 30, "reason": "insultos repetidos",
			"report_ids": []}), "el cuerpo de §6: el autor por id y el objetivo por el nombre escrito")
	assert_eq(reply, "Sanción aplicada: silencio a «bruno» hasta el %s." % ModerationService.date_text(NOW + 1800))
	assert_eq(bruno.chat.muted_until_unix, NOW + 1800, "silenciado ya en esta zona")
	var notices: Array[NetMessages.Notice] = _notices(bruno)
	assert_eq(notices.back().text if not notices.is_empty() else "",
			"Un moderador te ha silenciado 30 min: insultos repetidos", "Bruno sabe por qué")
	_chat(bruno, ChatChannel.Id.ZONE, "no me callo")
	await _advance(1)
	assert_eq(_last_system(bruno), "Estás silenciado 30 min más.", "con su tiempo restante")
	assert_false(_chat_lines(ana).has("Bruno: no me callo"), "no le llega a nadie")
	# La auditoría: actor por cuenta y personaje, source zone, el objetivo por id y sin nombres ni motivo.
	var entries: Array[Dictionary] = _entries_of("silenciar")
	if not assert_eq(entries.size(), 1, "una entrada de auditoría"):
		return
	var entry: Dictionary = entries[0]
	assert_eq([entry["source"], entry["actor_account_id"], entry["actor_character_id"]], ["zone", "1020", "102"])
	assert_eq([entry["target_character_id"], entry["target_account_id"]], ["103", "1030"])
	assert_eq(entry["args"], _json({"kind": "mute", "minutes": 30}))
	assert_eq(int(entry["at_unix"]), NOW)
	assert_false(JSON.stringify(entry).contains("Bruno") or JSON.stringify(entry).contains("insultos"),
			"ni nombres ni el motivo en la auditoría")
	assert_true(String(entry["key"]).begins_with(_platform.instance_id() + ":"), "la clave de la instancia")
	assert_eq(_entries_of("suspender"), [] as Array[Dictionary], "lo que no se ejecuta no se audita")


func test_a_debug_command_without_its_role_warns_and_does_nothing() -> void:
	if not await _start(true, true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var gema: ServerPeer = await _join(2, 102, VARDHEIM, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	var start: Vector3 = ana.entity.get_position()
	var strikes: int = ana.strikes_total
	_receive(ana, NetMessages.DebugCommand.teleport(Vector3(5.0, 0.0, 5.0)).encode())
	await _advance(2)
	assert_eq(ana.strikes_total, strikes + 1, "un aviso, como sin --debug-commands")
	assert_true(ana.entity.get_position().distance_to(start) < 0.5, "y no se mueve")
	assert_false(ana.entity.gm_forced)
	assert_eq(_entries_of("teleport"), [] as Array[Dictionary], "sin permiso no se audita en la plataforma")
	# El de gm sí, y queda marcado (no cobra hasta reaparecer, progresion.md §6.2).
	_receive(gema, NetMessages.DebugCommand.teleport(Vector3(5.0, 0.0, 5.0)).encode())
	await _advance(2)
	assert_true(gema.entity.get_position().distance_to(Vector3(5.0, 0.0, 5.0)) < 0.5, "se mueve")
	assert_true(gema.entity.gm_forced, "el teletransporte marca")
	var entries: Array[Dictionary] = _entries_of("teleport")
	if assert_eq(entries.size(), 1):
		assert_eq([entries[0]["source"], entries[0]["actor_character_id"], entries[0]["target_character_id"]],
				["zone", "102", "102"], "un DEBUG_COMMAND actúa sobre quien lo manda")
		assert_eq(entries[0]["args"], _json({"position": [5.0, 0.0, 5.0]}))
	await _die_and_respawn(gema.entity.net_id)
	assert_false(gema.entity.gm_forced, "la reaparición quita la marca")
	_receive(gema, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_HEAL).encode())
	await _advance(2)
	assert_true(gema.entity.gm_forced, "curarse también marca (2)")
	await _die_and_respawn(gema.entity.net_id)
	var stamina := NetMessages.DebugCommand.simple(NetProtocol.DEBUG_STAMINA_INF)
	stamina.payload = PackedByteArray([1])
	_receive(gema, stamina.encode())
	await _advance(2)
	assert_true(gema.entity.gm_forced, "y la resistencia infinita (4)")


func test_gm_teleport_and_visible_mark_and_invisible_hides_from_everything() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var gema: ServerPeer = await _join(2, 102, VARDHEIM, "Gema", &"gm")
	var sol: ServerPeer = await _join(3, 201, SOLMARCH, "Sol")
	if ana == null or ana.entity == null or gema == null or gema.entity == null or sol.entity == null:
		return
	var circle: Vector3 = FortressFixture.circle_center()
	_command(gema, "gm teleport ana %f %f %f" % [circle.x, circle.y, circle.z])
	await _advance(2)
	assert_true(ana.entity.get_position().distance_to(circle) < 0.5, "/gm teleport mueve a Ana")
	assert_true(ana.entity.gm_forced, "y la marca")
	assert_false(gema.entity.gm_forced, "a quien lo usa no")
	_command(gema, "gm teleport gema ana")
	await _advance(2)
	assert_true(gema.entity.get_position().distance_to(circle) < 1.0, "junto a otro jugador")
	gema.entity.gm_forced = false
	# Invisible: los demás reciben su DESPAWN en el acto y no cuenta en el círculo ni en el marcador.
	var gema_id: int = gema.entity.net_id
	_command(gema, "gm invisible")
	await _advance(1)
	assert_true(gema.entity.gm_invisible)
	assert_eq(_last_system(gema), ModerationService.TEXT_INVISIBLE)
	for other: ServerPeer in [ana, sol]:
		assert_false(other.relevant.has(gema_id), "%s ya no la tiene" % other.display_name)
		var gone: bool = false
		for bytes: PackedByteArray in _messages(other, NetProtocol.MSG_ENTITY_DESPAWN):
			if NetMessages.EntityDespawn.decode(bytes).net_id == gema_id:
				gone = true
		assert_true(gone, "%s recibe su DESPAWN" % other.display_name)
	assert_true(gema.relevant.has(ana.entity.net_id), "ella sigue viendo a los demás")
	await _advance(12)
	assert_false(ana.relevant.has(gema_id), "el interés no la vuelve a meter")
	var candidates: Array[int] = []
	for candidate: FortressController.PlayerCandidate in _server._presence_candidates(_server.get_tick()):
		candidates.append(candidate.net_id)
	assert_false(candidates.has(gema_id), "no cuenta en el círculo")
	assert_true(candidates.has(ana.entity.net_id))
	_server._send_scoreboard()
	var rows: Array[int] = []
	for bytes: PackedByteArray in _messages(ana, NetProtocol.MSG_SCOREBOARD):
		for row: NetMessages.ScoreRow in NetMessages.Scoreboard.decode(bytes).rows:
			rows.append(row.net_id)
	assert_true(rows.has(ana.entity.net_id) and not rows.has(gema_id), "ni en el marcador")
	var gema_combat: Combatant = _server.get_combat().get_combatant(gema_id)
	assert_true(gema_combat.is_gm_invisible(), "su combate la ve invisible (ni hace ni recibe daño)")
	_server._rebuild_target_cache()
	for realm: int in _server._targets_ids_by_realm:
		assert_false(_server._targets_ids_by_realm[realm].has(gema_id), "no es blanco de los bots")
	# Visible: vuelve a aparecer y queda marcada.
	_command(gema, "gm visible")
	await _advance(1)
	assert_false(gema.entity.gm_invisible)
	assert_true(gema.entity.gm_forced, "/gm visible marca a quien muestra")
	assert_true(ana.relevant.has(gema_id) and sol.relevant.has(gema_id), "los demás la vuelven a tener")
	var spawns: int = 0
	for bytes: PackedByteArray in _messages(sol, NetProtocol.MSG_ENTITY_SPAWN):
		if NetMessages.EntitySpawn.decode(bytes).net_id == gema_id:
			spawns += 1
	assert_eq(spawns, 2, "Sol recibe su SPAWN otra vez (el del alta y el de ahora)")
	# La reaparición quita la marca de los dos.
	await _die_and_respawn(ana.entity.net_id)
	assert_false(ana.entity.gm_forced)
	await _die_and_respawn(gema_id)
	assert_false(gema.entity.gm_forced)
	var invisible_entries: Array[Dictionary] = _entries_of("invisible")
	if assert_eq(invisible_entries.size(), 1, "invisible auditado"):
		assert_eq(invisible_entries[0]["target_character_id"], "102")
	assert_eq(_entries_of("visible").size(), 1, "y visible")


# --- Ignorados, reportes y silencios ----------------------------------------------------------------

func test_an_ignored_player_cannot_whisper_invite_or_reach_zone_chat() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var bruno: ServerPeer = await _join(2, 102, VARDHEIM, "Bruno")
	var cai: ServerPeer = await _join(3, 103, VARDHEIM, "Cai")
	if ana == null or bruno == null or cai == null:
		return
	var before: int = _system_texts(ana).size()
	_command(ana, "ignorar bruno")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_IGNORED % "Bruno")
	assert_eq(_platform.sent(PlatformEvent.KIND_IGNORE)[0], {"zone_instance_id": _platform.instance_id(),
			"character_id": "101", "target_name": "bruno"})
	assert_true(ana.chat.ignores_account(1020), "la cuenta de Bruno")
	_chat(bruno, ChatChannel.Id.WHISPER, "hola Ana", "Ana")
	_chat(bruno, ChatChannel.Id.ZONE, "hola zona")
	_receive(bruno, NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ana").encode())
	await _advance(1)
	assert_eq(_chat_lines(ana), PackedStringArray(), "a Ana no le llega ni el susurro ni la zona")
	assert_eq(_messages(ana, NetProtocol.MSG_PARTY_INVITATION).size(), 0, "ni la invitación")
	assert_true(_chat_lines(cai).has("Bruno: hola zona"), "a Cai sí")
	assert_true(_chat_lines(bruno).has("Bruno: hola Ana"), "Bruno ve su susurro como siempre")
	assert_true(_system_texts(bruno).has(PartyManager.TEXT_INVITED % "Ana"), "y su invitación como enviada")
	# Designorar: vuelve a llegar.
	before = _system_texts(ana).size()
	_command(ana, "designorar Bruno")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_UNIGNORED % "Bruno")
	assert_false(ana.chat.ignores_account(1020))
	_chat(bruno, ChatChannel.Id.ZONE, "ya me oyes")
	await _advance(1)
	assert_true(_chat_lines(ana).has("Bruno: ya me oyes"))
	# Errores: a sí misma, un nombre que no existe y el de la plataforma.
	_command(ana, "ignorar ana")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_IGNORE_SELF)
	before = _system_texts(ana).size()
	_command(ana, "ignorar Nadie")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_NOBODY % "Nadie")
	_platform.script_next(PlatformEvent.KIND_IGNORE, 409, FakeZonePlatform.error_body("ignore_list_full"))
	before = _system_texts(ana).size()
	_command(ana, "ignorar Cai")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_IGNORE_FULL)
	assert_false(ana.chat.ignores_account(1030))
	# Las cuentas ignoradas que trae la reclamación se aplican al entrar.
	_platform.set_account_state(104, 0, [1030])
	var dani: ServerPeer = await _join(4, 104, VARDHEIM, "Dani")
	_chat(cai, ChatChannel.Id.ZONE, "hola a todos")
	await _advance(1)
	assert_false(_chat_lines(dani).has("Cai: hola a todos"), "Dani ignora a Cai desde la reclamación")
	assert_true(_chat_lines(ana).has("Cai: hola a todos"))


func test_a_report_carries_its_evidence_and_waits_ten_minutes() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var bruno: ServerPeer = await _join(2, 102, VARDHEIM, "Bruno")
	var cai: ServerPeer = await _join(3, 103, VARDHEIM, "Cai")
	if ana == null or ana.entity == null or bruno == null or bruno.entity == null or cai == null:
		return
	_chat(bruno, ChatChannel.Id.WHISPER, "eres malísima", "Ana")
	await _advance(70)
	_chat(bruno, ChatChannel.Id.ZONE, "Ana no sabe jugar")
	_chat(cai, ChatChannel.Id.ZONE, "calma")
	await _advance(1)
	var before: int = _system_texts(ana).size()
	_command(ana, "reportar Bruno acoso me insulta sin parar")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_REPORT_SENT)
	var reports: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_REPORT)
	if not assert_eq(reports.size(), 1):
		return
	var report: Dictionary = reports[0]
	assert_eq([report["reporter_character_id"], report["target_name"], report["category"], report["comment"]],
			["101", "Bruno", "harassment", "me insulta sin parar"])
	assert_eq(report["evidence"], _json([
		{"sender_name": "Bruno", "channel": ChatChannel.Id.WHISPER, "text": "eres malísima", "sent_at_unix": NOW},
		{"sender_name": "Bruno", "channel": ChatChannel.Id.ZONE, "text": "Ana no sabe jugar", "sent_at_unix": NOW},
	]), "lo que Ana recibió de Bruno, sin lo de Cai")
	var context: Dictionary = report["context"]
	assert_eq(context["zone_id"], ZONE_ID)
	assert_true(context.has("tick") and context.has("reporter_position") and context.has("target_position"),
			"zona, tick y posiciones")
	# Otro reporte a Bruno en 10 min: la zona ya lo frena, sin pedir nada.
	_command(ana, "reportar bruno lenguaje otra vez")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_REPORT_AGAIN % ["bruno", 10])
	assert_eq(_platform.sent(PlatformEvent.KIND_REPORT).size(), 1, "una sola petición")
	# La plataforma también frena (10 por hora por cuenta): 429.
	_platform.script_next(PlatformEvent.KIND_REPORT, 429,
			FakeZonePlatform.error_body("rate_limited", "Espera", {"retry_after_s": 1500}))
	before = _system_texts(ana).size()
	_command(ana, "reportar Cai otro")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_REPORT_LIMITED % 25)
	# Un nombre que no existe no gasta el límite de la zona.
	before = _system_texts(ana).size()
	_command(ana, "reportar Nadie bot")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_NOBODY % "Nadie")
	assert_false(ana.chat.reported_at.has("nadie"), "no cuenta")
	# Uso y a sí misma (pasado el segundo de la ráfaga de hablar, que también gastan los comandos).
	await _advance(240)
	_command(ana, "reportar Bruno")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_REPORT_USAGE, "sin categoría")
	_command(ana, "reportar ana otro")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_REPORT_SELF)


func test_heartbeat_mutes_follow_the_platform_but_not_over_a_newer_sanction() -> void:
	if not await _start(true):
		return
	_platform.set_account_state(102, NOW + 600)
	var bruno: ServerPeer = await _join(2, 102, VARDHEIM, "Bruno")
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	if bruno == null or ana == null:
		return
	_chat(bruno, ChatChannel.Id.ZONE, "hola")
	await _advance(1)
	assert_eq(_last_system(bruno), "Estás silenciado 10 min más.", "el silencio de la reclamación")
	# El latido por Bruno sin su silencio (lo han levantado): vuelve a hablar.
	_platform._heartbeat_set[102] = bruno.claimed.lease_id
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": NOW, "revoked": [], "mutes": [],
			"maintenance": null})
	_platform.send_heartbeat_now()
	assert_true(await _advance_until(func() -> bool: return bruno.chat.muted_until_unix == 0, 120),
			"el latido levanta el silencio")
	# Un latido con su silencio lo pone; uno que no latió por él no lo toca.
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": NOW, "revoked": [],
			"mutes": [{"account_id": "1020", "until_unix": NOW + 120}, {"account_id": "1010", "until_unix": NOW + 60}],
			"maintenance": null})
	_platform.send_heartbeat_now()
	assert_true(await _advance_until(func() -> bool: return bruno.chat.muted_until_unix == NOW + 120, 120))
	assert_eq(ana.chat.muted_until_unix, 0, "Ana no estaba en ese latido")
	_chat(bruno, ChatChannel.Id.ZONE, "otra")
	await _advance(1)
	assert_eq(_last_system(bruno), "Estás silenciado 2 min más.")
	# Una sanción de la zona posterior al latido manda sobre él.
	bruno.chat.muted_until_unix = NOW + 3000
	bruno.chat.mute_changed_msec = Time.get_ticks_msec() + 60000
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": NOW, "revoked": [], "mutes": [],
			"maintenance": null})
	var beats: int = _server.get_moderation().get_stats()["heartbeats"]
	_platform.send_heartbeat_now()
	assert_true(await _advance_until(func() -> bool:
		return _server.get_moderation().get_stats()["heartbeats"] > beats, 120), "llega el latido")
	assert_eq(bruno.chat.muted_until_unix, NOW + 3000, "el latido viejo no deshace la sanción")


func test_rename_kicks_with_a_final_save_and_a_moderator_kick_respects_roles() -> void:
	if not await _start(true):
		return
	var gema: ServerPeer = await _join(1, 101, VARDHEIM, "Gema", &"gm")
	var mod: ServerPeer = await _join(2, 102, VARDHEIM, "Moira", &"moderator")
	var bruno: ServerPeer = await _join(3, 103, SOLMARCH, "Bruno")
	var cai: ServerPeer = await _join(4, 104, VARDHEIM, "Cai")
	if gema == null or mod == null or bruno == null or cai == null:
		return
	var before: int = _system_texts(gema).size()
	_command(gema, "gm renombrar Bruno nombre ofensivo")
	assert_eq(await _await_reply(gema, before), "Sanción aplicada: renombrado forzado a «Bruno».")
	var sanction: Dictionary = _platform.sent(PlatformEvent.KIND_SANCTION)[0]
	assert_eq([sanction["kind"], int(sanction["minutes"]), sanction["target_name"]], ["rename", 0, "Bruno"])
	assert_eq(bruno.state, ServerPeer.State.LEAVING, "Bruno sale para elegir otro nombre")
	assert_true(bruno.kicked)
	var notices: Array[NetMessages.Notice] = _notices(bruno)
	assert_eq([notices.back().code, notices.back().text], [NetProtocol.NoticeCode.KICK,
			ModerationService.TEXT_RENAME_KICK])
	assert_true(await _advance_until(func() -> bool:
		for body: Dictionary in _platform.sent(PlatformEvent.KIND_SAVE):
			if body.get("character_id") == "103" and bool(body.get("release_lease")):
				return int(body["reason"]) == CharacterSaver.Reason.KICK
		return false), "su guardado final, con el motivo 5")
	# Un moderador expulsa a un jugador, no a un gm.
	_command(mod, "gm expulsar Gema")
	await _advance(1)
	assert_eq(_last_system(mod), ModerationService.TEXT_KICK_DENIED % "Gema")
	assert_eq(gema.state, ServerPeer.State.IN_WORLD)
	_command(mod, "gm expulsar cai spam en el chat")
	await _advance(1)
	assert_eq(_last_system(mod), "«Cai» expulsado de la zona.")
	assert_eq(cai.state, ServerPeer.State.LEAVING)
	assert_eq(_notices(cai).back().text, "%s: spam en el chat" % ModerationService.TEXT_KICKED)
	assert_eq(_entries_of("expulsar").size(), 2, "los dos intentos ejecutados, auditados")
	# Un rechazo de la plataforma (el objetivo tiene un rol mayor o igual).
	_platform.script_next(PlatformEvent.KIND_SANCTION, 403, FakeZonePlatform.error_body("forbidden"))
	before = _system_texts(mod).size()
	_command(mod, "gm aviso Gema por probar")
	assert_eq(await _await_reply(mod, before), ModerationService.TEXT_SANCTION_FORBIDDEN % "Gema")


func test_warnings_show_on_entry_and_a_warning_reaches_who_is_here() -> void:
	if not await _start(true):
		return
	_platform.set_account_state(101, 0, [], [{"sanction_id": 7, "at_unix": NOW - 60,
			"text": "Has recibido un aviso de la moderación: lenguaje"}])
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var mod: ServerPeer = await _join(2, 102, VARDHEIM, "Moira", &"moderator")
	if ana == null or mod == null:
		return
	var texts: PackedStringArray = PackedStringArray()
	for notice: NetMessages.Notice in _notices(ana):
		texts.append(notice.text)
	assert_eq(texts, PackedStringArray(["Has recibido un aviso de la moderación: lenguaje"]), "el NOTICE al entrar")
	var before: int = _system_texts(mod).size()
	_command(mod, "gm aviso Ana sin insultos")
	assert_eq(await _await_reply(mod, before), "Sanción aplicada: aviso a «Ana».")
	assert_eq(_notices(ana).back().text, ModerationService.TEXT_WARNED % "sin insultos", "y el nuevo, ya")


# --- Lote de chat y ritmos por personaje ----------------------------------------------------------

func test_chat_goes_to_the_batch_and_rejoining_keeps_the_bursts() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var bruno: ServerPeer = await _join(2, 102, VARDHEIM, "Bruno")
	if ana == null or bruno == null:
		return
	_chat(ana, ChatChannel.Id.WHISPER, "hola", "Bruno")
	await _advance(1)
	var queued: Array[Dictionary] = _batch_entries(&"chat", "messages")
	if assert_eq(queued.size(), 1, "el susurro va al lote de chat"):
		assert_eq(_json([queued[0]["channel"], queued[0]["sender_character_id"], queued[0]["target_character_id"],
				queued[0]["text"], queued[0]["sent_at_unix"]]), _json([ChatChannel.Id.WHISPER, "101", "102", "hola", NOW]))
		assert_true(String(queued[0]["key"]).begins_with(_platform.instance_id() + ":"))
	for i: int in 5:
		_chat(ana, ChatChannel.Id.ZONE, "mensaje %d" % i)
	await _advance(1)
	_chat(ana, ChatChannel.Id.ZONE, "uno de más")
	await _advance(1)
	assert_eq(_last_system(ana), ChatRouter.TEXT_TOO_FAST, "la ráfaga gastada")
	# Sale y vuelve a entrar enseguida: el estado del chat es de su personaje.
	_server._mark_leaving(ana)
	await _advance_until(func() -> bool: return _server.get_saver().pending_count() == 0 \
			and not _server._peers.has(1))
	var again: ServerPeer = await _enter(5, _claim(101))
	if again == null:
		return
	var discarded: int = again.chat.discarded_rate
	_chat(again, ChatChannel.Id.ZONE, "he vuelto")
	await _advance(1)
	assert_eq(again.chat.discarded_rate, discarded + 1, "salir y volver no rellena las ráfagas")
	assert_false(_chat_lines(bruno).has("Ana: he vuelto"), "no sale")
	assert_eq(_server.get_social().get_stats()["reattached"], 1)


func test_without_the_platform_gm_is_unknown_and_ignoring_needs_accounts() -> void:
	if not await _start(false):
		return
	var ana: ServerPeer = await _enter(1, null, VARDHEIM, "Ana")
	if ana == null:
		return
	_command(ana, "gm teleport Ana 1 2 3")
	await _advance(1)
	assert_eq(_last_system(ana), UNKNOWN, "sin plataforma no hay roles")
	_command(ana, "ignorar Bruno")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_NO_PLATFORM)
	_command(ana, "reportar Bruno acoso")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_NO_PLATFORM)
	assert_eq(_server.console_command("silenciar Ana 30 x"), ModerationService.TEXT_SANCTION_CONSOLE,
			"las sanciones no salen de la consola")
