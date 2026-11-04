extends TestCase
## Tests for moderation in the zone (docs/plataforma.md §9 and §15, P7b): with no role, "Comando
## desconocido" (unknown command); a DEBUG_COMMAND with no role, a warning and nothing else;
## [code]/gm silenciar[/code] on a player and on a moderator; the mute with its remaining time, from the
## sanction and from the heartbeat; the audit entry with the GM's account and [code]source[/code]
## [code]zone[/code]; [code]/gm teleport[/code] and [code]/gm visible[/code] flag with
## [code]gm_forced[/code] and respawning removes it; the invisible GM outside interest, the circle and
## the scoreboard; an ignored player cannot whisper, invite or reach their zone channel; the report with
## its evidence and its limit; the forced rename; the kick of a moderator; the warnings on entry; the
## chat batch; and leaving and returning does not refill the bursts.
## [br][br]
## A network-less [ZoneServer] over the flat zone with the test fortress, with [FakeZonePlatform] (clock
## fixed and heartbeat by hand) and peers set up by hand with their claim, like test_progress_rewards.gd;
## what reaches each peer is recorded by a fake transport, and client messages enter through
## [code]_on_packet_received[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const UNKNOWN: String = "Comando desconocido. Escribe /ayuda."


## A transport that connects nothing and records what the server sends to each peer (without the SNAPSHOTs).
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


# --- Setup ------------------------------------------------------------------------------------

## The flat zone with the test fortress and the network-less server; with [param with_platform], the fake
## platform started and alive, with the clock at [constant NOW] and no automatic heartbeats (they are sent by hand).
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
		if not assert_eq(finished, [[true, ""]], "the fake platform starts"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "the server starts"):
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
		if not assert_true(ready, "the first block of ids arrives"):
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


## The character [param character_id] (account [code]character_id × 10[/code], [param role]) enters with
## peer [param peer_id]. Returns the peer, already in the world.
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
		assert_true(_server.get_progress().prepare(peer_id, claimed), "the record is prepared")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "peer %d enters the world" % peer_id)
	return peer


func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	return ClaimedCharacter.from_claim(JSON.parse_string(JSON.stringify(answer[1])))


## What [param peer]'s client sends (a CHAT_SEND, a DEBUG_COMMAND...), exactly as it arrives from the transport.
func _receive(peer: ServerPeer, bytes: PackedByteArray) -> void:
	_server._on_packet_received(peer.peer_id, bytes)


func _chat(peer: ServerPeer, channel: int, text: String, recipient: String = "") -> void:
	var message := NetMessages.ChatSend.new()
	message.channel = channel
	message.recipient = recipient
	message.text = text
	_receive(peer, message.encode())


## A command line (what the client sends on the GM channel, without the slash).
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


## Waits for [param peer] to receive a new system text (after [param before]).
func _await_reply(peer: ServerPeer, before: int) -> String:
	await _advance_until(func() -> bool: return _system_texts(peer).size() > before, 300)
	return _last_system(peer)


## The entries of the [param kind] batch (its list is called [param field] in the body), sent and queued,
## with the round trip through JSON (numbers as floating point, as the fake platform reads them).
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


## [param value] after the round trip through JSON, to compare with what the fake platform receives.
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
			CombatDirector.RespawnRequestResult.ACCEPTED, "requests respawn")
	await _advance(10)
	assert_true(combatant.is_alive(), "has respawned")


# --- /gm and the role ---------------------------------------------------------------------------------

func test_gm_needs_its_role_a_moderator_mutes_and_the_audit_says_who() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM, "Ana")
	var mod: ServerPeer = await _join(2, 102, VARDHEIM, "Moira", &"moderator")
	var bruno: ServerPeer = await _join(3, 103, VARDHEIM, "Bruno")
	if ana == null or mod == null or bruno == null or bruno.entity == null:
		return
	# With no role: the same as a command that does not exist, and nothing goes out to the platform.
	for line: String in ["gm silenciar Bruno 30 insultos", "gm ayuda", "gm", "gm volar", "xyz Bruno"]:
		_command(ana, line)
		await _advance(1)
		assert_eq(_last_system(ana), UNKNOWN, "\"%s\" from a player" % line)
	assert_eq(_platform.sent(PlatformEvent.KIND_SANCTION).size(), 0, "no sanction requested")
	# A moderator does not have the gm ones, and help only shows them their own.
	_command(mod, "gm suspender Bruno 1d spam")
	await _advance(1)
	assert_eq(_last_system(mod), UNKNOWN, "suspending is for gm")
	_command(mod, "gm ayuda")
	await _advance(1)
	var help: String = _last_system(mod)
	assert_true(help.contains("silenciar") and help.contains("aviso") and help.contains("expulsar"), help)
	assert_false(help.contains("teleport") or help.contains("suspender") or help.contains("banear"), help)
	# The moderator mutes: the platform authorizes it and it applies right away.
	var before: int = _system_texts(mod).size()
	_command(mod, "gm Silenciar bruno 30 insultos repetidos")
	var reply: String = await _await_reply(mod, before)
	var requests: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_SANCTION)
	if not assert_eq(requests.size(), 1, "one sanction requested"):
		return
	assert_eq(requests[0], _json({"zone_instance_id": _platform.instance_id(), "author_character_id": "102",
			"target_name": "bruno", "kind": "mute", "minutes": 30, "reason": "insultos repetidos",
			"report_ids": []}), "the §6 body: the author by id and the target by the typed name")
	assert_eq(reply, "Sanción aplicada: silencio a «bruno» hasta el %s." % ModerationService.date_text(NOW + 1800))
	assert_eq(bruno.chat.muted_until_unix, NOW + 1800, "already muted in this zone")
	var notices: Array[NetMessages.Notice] = _notices(bruno)
	assert_eq(notices.back().text if not notices.is_empty() else "",
			"Un moderador te ha silenciado 30 min: insultos repetidos", "Bruno knows why")
	_chat(bruno, ChatChannel.Id.ZONE, "no me callo")
	await _advance(1)
	assert_eq(_last_system(bruno), "Estás silenciado 30 min más.", "with its remaining time")
	assert_false(_chat_lines(ana).has("Bruno: no me callo"), "it reaches no one")
	# The audit: actor by account and character, source zone, the target by id and with no names or reason.
	var entries: Array[Dictionary] = _entries_of("silenciar")
	if not assert_eq(entries.size(), 1, "one audit entry"):
		return
	var entry: Dictionary = entries[0]
	assert_eq([entry["source"], entry["actor_account_id"], entry["actor_character_id"]], ["zone", "1020", "102"])
	assert_eq([entry["target_character_id"], entry["target_account_id"]], ["103", "1030"])
	assert_eq(entry["args"], _json({"kind": "mute", "minutes": 30}))
	assert_eq(int(entry["at_unix"]), NOW)
	assert_false(JSON.stringify(entry).contains("Bruno") or JSON.stringify(entry).contains("insultos"),
			"no names or reason in the audit")
	assert_true(String(entry["key"]).begins_with(_platform.instance_id() + ":"), "the instance's key")
	assert_eq(_entries_of("suspender"), [] as Array[Dictionary], "what is not executed is not audited")


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
	assert_eq(ana.strikes_total, strikes + 1, "a warning, as without --debug-commands")
	assert_true(ana.entity.get_position().distance_to(start) < 0.5, "and it does not move")
	assert_false(ana.entity.gm_forced)
	assert_eq(_entries_of("teleport"), [] as Array[Dictionary], "without permission it is not audited on the platform")
	# The gm one does, and it gets flagged (it earns nothing until respawn, progresion.md §6.2).
	_receive(gema, NetMessages.DebugCommand.teleport(Vector3(5.0, 0.0, 5.0)).encode())
	await _advance(2)
	assert_true(gema.entity.get_position().distance_to(Vector3(5.0, 0.0, 5.0)) < 0.5, "it moves")
	assert_true(gema.entity.gm_forced, "the teleport flags")
	var entries: Array[Dictionary] = _entries_of("teleport")
	if assert_eq(entries.size(), 1):
		assert_eq([entries[0]["source"], entries[0]["actor_character_id"], entries[0]["target_character_id"]],
				["zone", "102", "102"], "a DEBUG_COMMAND acts on whoever sends it")
		assert_eq(entries[0]["args"], _json({"position": [5.0, 0.0, 5.0]}))
	await _die_and_respawn(gema.entity.net_id)
	assert_false(gema.entity.gm_forced, "respawning removes the flag")
	_receive(gema, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_HEAL).encode())
	await _advance(2)
	assert_true(gema.entity.gm_forced, "healing also flags (2)")
	await _die_and_respawn(gema.entity.net_id)
	var stamina := NetMessages.DebugCommand.simple(NetProtocol.DEBUG_STAMINA_INF)
	stamina.payload = PackedByteArray([1])
	_receive(gema, stamina.encode())
	await _advance(2)
	assert_true(gema.entity.gm_forced, "and infinite stamina (4)")


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
	assert_true(ana.entity.get_position().distance_to(circle) < 0.5, "/gm teleport moves Ana")
	assert_true(ana.entity.gm_forced, "and the flag")
	assert_false(gema.entity.gm_forced, "not the one who uses it")
	_command(gema, "gm teleport gema ana")
	await _advance(2)
	assert_true(gema.entity.get_position().distance_to(circle) < 1.0, "next to another player")
	gema.entity.gm_forced = false
	# Invisible: the others receive her DESPAWN immediately and she counts neither in the circle nor on the scoreboard.
	var gema_id: int = gema.entity.net_id
	_command(gema, "gm invisible")
	await _advance(1)
	assert_true(gema.entity.gm_invisible)
	assert_eq(_last_system(gema), ModerationService.TEXT_INVISIBLE)
	for other: ServerPeer in [ana, sol]:
		assert_false(other.relevant.has(gema_id), "%s no longer has her" % other.display_name)
		var gone: bool = false
		for bytes: PackedByteArray in _messages(other, NetProtocol.MSG_ENTITY_DESPAWN):
			if NetMessages.EntityDespawn.decode(bytes).net_id == gema_id:
				gone = true
		assert_true(gone, "%s receives her DESPAWN" % other.display_name)
	assert_true(gema.relevant.has(ana.entity.net_id), "she still sees the others")
	await _advance(12)
	assert_false(ana.relevant.has(gema_id), "interest does not put her back in")
	var candidates: Array[int] = []
	for candidate: FortressController.PlayerCandidate in _server._presence_candidates(_server.get_tick()):
		candidates.append(candidate.net_id)
	assert_false(candidates.has(gema_id), "she does not count in the circle")
	assert_true(candidates.has(ana.entity.net_id))
	_server._send_scoreboard()
	var rows: Array[int] = []
	for bytes: PackedByteArray in _messages(ana, NetProtocol.MSG_SCOREBOARD):
		for row: NetMessages.ScoreRow in NetMessages.Scoreboard.decode(bytes).rows:
			rows.append(row.net_id)
	assert_true(rows.has(ana.entity.net_id) and not rows.has(gema_id), "nor on the scoreboard")
	var gema_combat: Combatant = _server.get_combat().get_combatant(gema_id)
	assert_true(gema_combat.is_gm_invisible(), "combat sees her as invisible (she neither deals nor takes damage)")
	_server._rebuild_target_cache()
	for realm: int in _server._targets_ids_by_realm:
		assert_false(_server._targets_ids_by_realm[realm].has(gema_id), "she is not a bot target")
	# Visible: she appears again and is flagged.
	_command(gema, "gm visible")
	await _advance(1)
	assert_false(gema.entity.gm_invisible)
	assert_true(gema.entity.gm_forced, "/gm visible flags whoever it shows")
	assert_true(ana.relevant.has(gema_id) and sol.relevant.has(gema_id), "the others have her again")
	var spawns: int = 0
	for bytes: PackedByteArray in _messages(sol, NetProtocol.MSG_ENTITY_SPAWN):
		if NetMessages.EntitySpawn.decode(bytes).net_id == gema_id:
			spawns += 1
	assert_eq(spawns, 2, "Sol receives her SPAWN again (the sign-up one and the current one)")
	# Respawning removes the flag from both.
	await _die_and_respawn(ana.entity.net_id)
	assert_false(ana.entity.gm_forced)
	await _die_and_respawn(gema_id)
	assert_false(gema.entity.gm_forced)
	var invisible_entries: Array[Dictionary] = _entries_of("invisible")
	if assert_eq(invisible_entries.size(), 1, "invisible audited"):
		assert_eq(invisible_entries[0]["target_character_id"], "102")
	assert_eq(_entries_of("visible").size(), 1, "and visible")


# --- Ignored players, reports and mutes ----------------------------------------------------------

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
	assert_true(ana.chat.ignores_account(1020), "Bruno's account")
	_chat(bruno, ChatChannel.Id.WHISPER, "hola Ana", "Ana")
	_chat(bruno, ChatChannel.Id.ZONE, "hola zona")
	_receive(bruno, NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ana").encode())
	await _advance(1)
	assert_eq(_chat_lines(ana), PackedStringArray(), "Ana receives neither the whisper nor the zone message")
	assert_eq(_messages(ana, NetProtocol.MSG_PARTY_INVITATION).size(), 0, "nor the invitation")
	assert_true(_chat_lines(cai).has("Bruno: hola zona"), "Cai does")
	assert_true(_chat_lines(bruno).has("Bruno: hola Ana"), "Bruno sees his whisper as usual")
	assert_true(_system_texts(bruno).has(PartyManager.TEXT_INVITED % "Ana"), "and his invitation as sent")
	# Un-ignore: it arrives again.
	before = _system_texts(ana).size()
	_command(ana, "designorar Bruno")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_UNIGNORED % "Bruno")
	assert_false(ana.chat.ignores_account(1020))
	_chat(bruno, ChatChannel.Id.ZONE, "ya me oyes")
	await _advance(1)
	assert_true(_chat_lines(ana).has("Bruno: ya me oyes"))
	# Errors: to herself, a name that does not exist and the platform's.
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
	# The ignored accounts carried by the claim are applied on entry.
	_platform.set_account_state(104, 0, [1030])
	var dani: ServerPeer = await _join(4, 104, VARDHEIM, "Dani")
	_chat(cai, ChatChannel.Id.ZONE, "hola a todos")
	await _advance(1)
	assert_false(_chat_lines(dani).has("Cai: hola a todos"), "Dani ignores Cai since the claim")
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
	]), "what Ana received from Bruno, without Cai's")
	var context: Dictionary = report["context"]
	assert_eq(context["zone_id"], ZONE_ID)
	assert_true(context.has("tick") and context.has("reporter_position") and context.has("target_position"),
			"zone, tick and positions")
	# Another report on Bruno within 10 min: the zone already throttles it, without requesting anything.
	_command(ana, "reportar bruno lenguaje otra vez")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_REPORT_AGAIN % ["bruno", 10])
	assert_eq(_platform.sent(PlatformEvent.KIND_REPORT).size(), 1, "a single request")
	# The platform also throttles (10 per hour per account): 429.
	_platform.script_next(PlatformEvent.KIND_REPORT, 429,
			FakeZonePlatform.error_body("rate_limited", "Espera", {"retry_after_s": 1500}))
	before = _system_texts(ana).size()
	_command(ana, "reportar Cai otro")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_REPORT_LIMITED % 25)
	# A name that does not exist does not use up the zone's limit.
	before = _system_texts(ana).size()
	_command(ana, "reportar Nadie bot")
	assert_eq(await _await_reply(ana, before), ModerationService.TEXT_NOBODY % "Nadie")
	assert_false(ana.chat.reported_at.has("nadie"), "it does not count")
	# Usage and to herself (after the one-second talk burst, which commands also consume).
	await _advance(240)
	_command(ana, "reportar Bruno")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_REPORT_USAGE, "no category")
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
	assert_eq(_last_system(bruno), "Estás silenciado 10 min más.", "the mute from the claim")
	# The heartbeat for Bruno without his mute (it has been lifted): he can talk again.
	_platform._heartbeat_set[102] = bruno.claimed.lease_id
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": NOW, "revoked": [], "mutes": [],
			"maintenance": null})
	_platform.send_heartbeat_now()
	assert_true(await _advance_until(func() -> bool: return bruno.chat.muted_until_unix == 0, 120),
			"the heartbeat lifts the mute")
	# A heartbeat with its mute sets it; one that did not beat for him does not touch it.
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": NOW, "revoked": [],
			"mutes": [{"account_id": "1020", "until_unix": NOW + 120}, {"account_id": "1010", "until_unix": NOW + 60}],
			"maintenance": null})
	_platform.send_heartbeat_now()
	assert_true(await _advance_until(func() -> bool: return bruno.chat.muted_until_unix == NOW + 120, 120))
	assert_eq(ana.chat.muted_until_unix, 0, "Ana was not in that heartbeat")
	_chat(bruno, ChatChannel.Id.ZONE, "otra")
	await _advance(1)
	assert_eq(_last_system(bruno), "Estás silenciado 2 min más.")
	# A zone sanction later than the heartbeat takes precedence over it.
	bruno.chat.muted_until_unix = NOW + 3000
	bruno.chat.mute_changed_msec = Time.get_ticks_msec() + 60000
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": NOW, "revoked": [], "mutes": [],
			"maintenance": null})
	var beats: int = _server.get_moderation().get_stats()["heartbeats"]
	_platform.send_heartbeat_now()
	assert_true(await _advance_until(func() -> bool:
		return _server.get_moderation().get_stats()["heartbeats"] > beats, 120), "the heartbeat arrives")
	assert_eq(bruno.chat.muted_until_unix, NOW + 3000, "the old heartbeat does not undo the sanction")


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
	assert_eq(bruno.state, ServerPeer.State.LEAVING, "Bruno leaves to pick another name")
	assert_true(bruno.kicked)
	var notices: Array[NetMessages.Notice] = _notices(bruno)
	assert_eq([notices.back().code, notices.back().text], [NetProtocol.NoticeCode.KICK,
			ModerationService.TEXT_RENAME_KICK])
	assert_true(await _advance_until(func() -> bool:
		for body: Dictionary in _platform.sent(PlatformEvent.KIND_SAVE):
			if body.get("character_id") == "103" and bool(body.get("release_lease")):
				return int(body["reason"]) == CharacterSaver.Reason.KICK
		return false), "his final save, with reason 5")
	# A moderator kicks a player, not a gm.
	_command(mod, "gm expulsar Gema")
	await _advance(1)
	assert_eq(_last_system(mod), ModerationService.TEXT_KICK_DENIED % "Gema")
	assert_eq(gema.state, ServerPeer.State.IN_WORLD)
	_command(mod, "gm expulsar cai spam en el chat")
	await _advance(1)
	assert_eq(_last_system(mod), "«Cai» expulsado de la zona.")
	assert_eq(cai.state, ServerPeer.State.LEAVING)
	assert_eq(_notices(cai).back().text, "%s: spam en el chat" % ModerationService.TEXT_KICKED)
	assert_eq(_entries_of("expulsar").size(), 2, "both attempts executed, audited")
	# A rejection from the platform (the target has an equal or higher role).
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
	assert_eq(texts, PackedStringArray(["Has recibido un aviso de la moderación: lenguaje"]), "the NOTICE on entry")
	var before: int = _system_texts(mod).size()
	_command(mod, "gm aviso Ana sin insultos")
	assert_eq(await _await_reply(mod, before), "Sanción aplicada: aviso a «Ana».")
	assert_eq(_notices(ana).back().text, ModerationService.TEXT_WARNED % "sin insultos", "and the new one, immediately")


# --- Chat batch and per-character rates ----------------------------------------------------------

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
	if assert_eq(queued.size(), 1, "the whisper goes into the chat batch"):
		assert_eq(_json([queued[0]["channel"], queued[0]["sender_character_id"], queued[0]["target_character_id"],
				queued[0]["text"], queued[0]["sent_at_unix"]]), _json([ChatChannel.Id.WHISPER, "101", "102", "hola", NOW]))
		assert_true(String(queued[0]["key"]).begins_with(_platform.instance_id() + ":"))
	for i: int in 5:
		_chat(ana, ChatChannel.Id.ZONE, "mensaje %d" % i)
	await _advance(1)
	_chat(ana, ChatChannel.Id.ZONE, "uno de más")
	await _advance(1)
	assert_eq(_last_system(ana), ChatRouter.TEXT_TOO_FAST, "the burst is spent")
	# Leaves and re-enters right away: the chat state belongs to the character.
	_server._mark_leaving(ana)
	await _advance_until(func() -> bool: return _server.get_saver().pending_count() == 0 \
			and not _server._peers.has(1))
	var again: ServerPeer = await _enter(5, _claim(101))
	if again == null:
		return
	var discarded: int = again.chat.discarded_rate
	_chat(again, ChatChannel.Id.ZONE, "he vuelto")
	await _advance(1)
	assert_eq(again.chat.discarded_rate, discarded + 1, "leaving and returning does not refill the bursts")
	assert_false(_chat_lines(bruno).has("Ana: he vuelto"), "it does not go out")
	assert_eq(_server.get_social().get_stats()["reattached"], 1)


func test_without_the_platform_gm_is_unknown_and_ignoring_needs_accounts() -> void:
	if not await _start(false):
		return
	var ana: ServerPeer = await _enter(1, null, VARDHEIM, "Ana")
	if ana == null:
		return
	_command(ana, "gm teleport Ana 1 2 3")
	await _advance(1)
	assert_eq(_last_system(ana), UNKNOWN, "without a platform there are no roles")
	_command(ana, "ignorar Bruno")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_NO_PLATFORM)
	_command(ana, "reportar Bruno acoso")
	await _advance(1)
	assert_eq(_last_system(ana), ModerationService.TEXT_NO_PLATFORM)
	assert_eq(_server.console_command("silenciar Ana 30 x"), ModerationService.TEXT_SANCTION_CONSOLE,
			"sanctions do not go out from the console")
