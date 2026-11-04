extends TestCase
## Tests for the progression GM commands (docs/progression.md §10 and §15, P5d; PRG-16): giving an item,
## splitting it, merging it and reverting it (the total drops by what was given and the GM_GRANT, the REVERSAL and their ledger entries are there); the
## second reversal, also the one that arrives before the first is saved; DEBUG_COMMAND with platform and its role (41 from a
## [code]player[/code], 40 and 16 from a [code]gm[/code]: warning and nothing; the 16 from an [code]admin[/code], a GM that the
## save accepts; 5 and 13, audit only); the rule about one's own characters (also in [code]dev[/code]);
## the target by its [code]character_id[/code]; the fenced zone; [code]level_set[/code] and [code]xp_add[/code] with their
## [code]detail[/code]; [code]ledger_show[/code] and [code]op_show[/code] through the routes; and without a platform, the journal.
## Also, the base: the uids of the body's events versus what was saved (S4) and [method PlayerProgress.abort_op].
## [br][br]
## A [ZoneServer] without networking on the flat zone with the test fortress, with [FakeZonePlatform] (fixed clock) and
## peers assembled by hand with their claim, like test_zone_moderation.gd. The responses of the §13.2 routes are
## scripted with [method FakeZonePlatform.script_next] from what was actually saved, and each saved body
## goes through the S2, S4 and S5 shape checks that can be done without a database ([method _assert_saves_accepted]).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const ZONE_ID: String = "test_world"
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const POTION: StringName = &"potion_health"
const STAMINA: StringName = &"potion_stamina"
const GOLD: int = Currency.Code.GOLD
## The detail keys that S2 accepts (progression.md §10; checks.go of P7).
const DETAIL_KEYS: Array[String] = ["command", "args", "source", "actor_character_id", "at_unix", "level_before",
		"level_after", "xp_before", "xp_after", "xp_delta"]
const PLATFORM_DOWN: String = "El servicio de cuentas no responde; inténtalo más tarde."
const OWN: String = "No puedes usarlo sobre tus personajes."


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
var _request_id: int = 0
var _console: PackedStringArray = PackedStringArray()


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
	_console = PackedStringArray()
	await wait_process_frames()


# --- Setup ------------------------------------------------------------------------------------

## The flat zone with the test fortress and the server without networking, with [code]--debug-commands[/code]; with
## [param with_platform], the fake platform (with [param env]) started and alive, with the clock at [constant NOW] and no
## heartbeats of its own.
func _start(with_platform: bool, env: StringName = &"test") -> bool:
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
	config.debug_commands = true
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_platform.fake_heartbeat_s = 600.0
		_platform.fake_env = env
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
	# What the commands leave in the log (console replies that arrive late).
	_progress().log_sink = func(text: String) -> void: _console.append(text)
	_server.get_moderation().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	if with_platform:
		_platform.go_live()
		var ready: bool = await _advance_until(func() -> bool: return _progress().get_ids().available() > 0)
		if not assert_true(ready, "the first block of ids arrives"):
			return false
	return true


func _progress() -> ProgressService:
	return _server.get_progress()


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


## Character [param character_id] (account [code]character_id × 10[/code], [param role]) enters with peer
## [param peer_id]. Returns the peer, already in the world.
func _join(peer_id: int, character_id: int, display_name: String, role: StringName = &"player") -> ServerPeer:
	_platform.add_character(character_id, character_id * 10, role, VARDHEIM, {}, {}, display_name)
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	return await _enter(peer_id, ClaimedCharacter.from_claim(JSON.parse_string(JSON.stringify(answer[1]))),
			display_name)


func _enter(peer_id: int, claimed: ClaimedCharacter, display_name: String) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm if claimed != null else VARDHEIM
	peer.display_name = claimed.display_name if claimed != null else display_name
	peer.loading_since_tick = _server.get_tick()
	peer.remote_address = "127.0.0.1"
	_server._peers[peer_id] = peer
	if claimed != null:
		peer.claimed = claimed
		assert_true(_progress().prepare(peer_id, claimed), "the log is prepared")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "peer %d enters the world" % peer_id)
	return peer


## Waits until nothing is left to save: no save in flight and the journals confirmed.
func _settle() -> bool:
	return await _advance_until(func() -> bool:
		if _server.get_saver().pending_count() > 0:
			return false
		for net_id: int in _progress().player_net_ids():
			if not _progress().get_player(net_id).journal().is_empty():
				return false
		return true)


func _receive(peer: ServerPeer, bytes: PackedByteArray) -> void:
	_server._on_packet_received(peer.peer_id, bytes)


## A [code]/gm[/code] line (what the client sends over the GM channel, without the slash) and the new
## [param replies] replies from the system channel.
func _gm(peer: ServerPeer, line: String, replies: int = 1) -> PackedStringArray:
	# The speak token: one per second.
	await _advance(60)
	var before: int = _system_texts(peer).size()
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.GM
	message.text = line
	_receive(peer, message.encode())
	await _advance_until(func() -> bool: return _system_texts(peer).size() >= before + replies, 300)
	return _system_texts(peer).slice(before)


func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for bytes: PackedByteArray in _recorder.sent.get(peer.peer_id, []):
		if NetMessages.peek_type(bytes) != NetProtocol.MSG_CHAT_MESSAGE:
			continue
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null and message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _messages(peer: ServerPeer, type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _recorder.sent.get(peer.peer_id, []):
		if NetMessages.peek_type(bytes) == type:
			found.append(bytes)
	return found


## The player's own LOADOUT ENTITY_EVENTs that [param peer] has received.
func _loadouts(peer: ServerPeer) -> int:
	var count: int = 0
	for bytes: PackedByteArray in _messages(peer, NetProtocol.MSG_ENTITY_EVENT):
		var decoded: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
		if decoded != null and decoded.event == NetMessages.EntityEvent.Kind.LOADOUT \
				and decoded.net_id == peer.entity.net_id:
			count += 1
	return count


func _player(peer: ServerPeer) -> PlayerProgress:
	return _progress().get_player(peer.entity.net_id)


func _count(peer: ServerPeer, def_id: StringName) -> int:
	return _player(peer).record.inventory.count_of(def_id)


func _last_op(peer: ServerPeer) -> EconomyOp:
	var journal: Array[EconomyOp] = _player(peer).journal()
	return journal.back() if not journal.is_empty() else null


func _request(peer: ServerPeer, op: int, from_container: int, from_slot: int, to_container: int, to_slot: int,
		count: int, uid: int) -> void:
	_request_id += 1
	var request: InventoryOps.Request = InventoryOps.make_request(op, from_container, from_slot, to_container,
			to_slot, count, uid)
	_receive(peer, ProgressMessages.InventoryRequest.from_request(_request_id, request).encode())


## The bag slot of [param def_id] that is none of [param skip] (−1 if there is none).
func _bag_slot_of(peer: ServerPeer, def_id: StringName, skip: Array[int] = []) -> int:
	var state: InventoryState = _player(peer).record.inventory
	for slot: int in range(state.bag_slots):
		var item: ItemInstance = state.get_item(BAG, slot)
		if item != null and item.def_id == def_id and not skip.has(slot):
			return slot
	return -1


## The save bodies of [param character_id], in order (without the retries of the same seq).
func _saves_of(character_id: int) -> Array[Dictionary]:
	var bodies: Array[Dictionary] = []
	var last_seq: int = -1
	for body: Dictionary in _platform.sent(PlatformEvent.KIND_SAVE):
		if body.get("character_id") == str(character_id) and body.get("progress") is Dictionary \
				and int(body.get("seq", 0)) != last_seq:
			last_seq = int(body["seq"])
			bodies.append(body)
	return bodies


## Operation [param op_id] as saved by [param character_id] (the ops entry from §9.3), or empty.
func _saved_op(character_id: int, op_id: int) -> Dictionary:
	for body: Dictionary in _saves_of(character_id):
		for op: Dictionary in body["progress"]["ops"]:
			if op["op_id"] == str(op_id):
				return op
	return {}


## The body of [code]GET /internal/v1/ops/{op_id}[/code] (§13.2) for what [param character_id] saved, with
## [param reversed_by] and the rows of its events' uids (from the last saved snapshot that carries them).
func _route_body(character_id: int, op_id: int, reversed_by: int = 0) -> Dictionary:
	var op: Dictionary = _saved_op(character_id, op_id)
	var ledger: Array = []
	var seq: int = 0
	for entry: Dictionary in op.get("ledger", []):
		seq += 1
		ledger.append({"character_id": str(character_id), "currency": entry["currency"], "seq": seq,
				"delta": entry["delta"], "balance_after": entry["balance_after"], "reason": entry["reason"],
				"ref_kind": entry["ref_kind"], "ref_id": entry["ref_id"]})
	var items: Array = []
	var instances: Array = []
	for event: Dictionary in op.get("items", []):
		items.append({"character_id": str(character_id), "uid": event["uid"], "def_id": event["def_id"],
				"count_delta": event["count_delta"], "reason": event["reason"]})
		if event["uid"] != null:
			var row: Dictionary = _instance_row(character_id, String(event["uid"]))
			if not row.is_empty():
				instances.append(row)
	return {"op": {"op_id": str(op_id), "kind": op.get("kind"), "actor_account_id": op.get("actor_account_id"),
			"ref_op_id": op.get("ref_op_id"), "zone_id": ZONE_ID, "note": op.get("note"), "detail": op.get("detail"),
			"created_at_unix": NOW, "participants": [str(character_id)],
			"reversed_by": str(reversed_by) if reversed_by != 0 else null, "ledger": ledger, "items": items,
			"instances": instances}}


func _instance_row(character_id: int, uid: String) -> Dictionary:
	var bodies: Array[Dictionary] = _saves_of(character_id)
	for i: int in range(bodies.size() - 1, -1, -1):
		for item: Dictionary in bodies[i]["progress"]["items"]:
			if item["uid"] == uid:
				return {"uid": uid, "def_id": item["def_id"], "count": item["count"], "durability": item["durability"],
						"rarity": item["rarity"], "bound": item["bound"], "seed": item["seed"],
						"affixes": item["affixes"], "retired": i < bodies.size() - 1}
	return {}


## The S2, S4 and S5 shape checks that can be done without a database (progression.md §13.3) on each saved body
## of [param character_id], in order: each operation with the reasons for its type and, GM and REVERSAL, with
## [code]note[/code] and a [code]detail[/code] that S2 reads (its keys, [code]source[/code], [code]args[/code] as
## strings and [code]at_unix[/code]); by definition, what was saved plus the events is the snapshot; an event with a uid that adds
## belongs to one that was not saved and one that subtracts, to one that was; and the active slot with a weapon.
func _assert_saves_accepted(character_id: int) -> void:
	var saved: Dictionary = {}
	for body: Dictionary in _saves_of(character_id):
		var progress: Dictionary = body["progress"]
		var totals: Dictionary = {}
		for uid: String in saved:
			totals[saved[uid][0]] = int(totals.get(saved[uid][0], 0)) + int(saved[uid][1])
		for op: Dictionary in progress["ops"]:
			var parsed: EconomyOp = EconomyOp.from_dictionary(op)
			if not assert_not_null(parsed, "operation %s is read" % op.get("op_id")):
				continue
			assert_true(parsed.is_consistent(), "S2: the reasons for its type and the note (%s)" % op["op_id"])
			if parsed.kind == EconomyOp.Kind.GM or parsed.kind == EconomyOp.Kind.REVERSAL:
				for key: String in parsed.detail:
					assert_true(DETAIL_KEYS.has(key), "S2: detail without the key %s" % key)
				assert_true(["gm", "console", "debug"].has(parsed.detail.get("source")), "S2: source")
				assert_eq(int(parsed.detail.get("at_unix", -1)), NOW, "S2: at_unix from the zone")
				for arg: Variant in parsed.detail.get("args", []):
					assert_true(arg is String, "S2: args as strings")
				var console: bool = parsed.detail.get("source") == "console"
				assert_eq(parsed.actor_account_id == 0, console, "S2: actor only outside the console")
			for event: Dictionary in op["items"]:
				var def_id: String = event["def_id"]
				totals[def_id] = int(totals.get(def_id, 0)) + int(event["count_delta"])
				if event["uid"] == null:
					continue
				if int(event["count_delta"]) > 0:
					assert_false(saved.has(event["uid"]), "S4: adds to a uid that was not there (%s)" % event["uid"])
				else:
					assert_eq((saved.get(event["uid"], ["", 0]) as Array)[0], def_id,
							"S4: subtracts from a uid that was there (%s)" % event["uid"])
		saved = {}
		var weapons: Array[int] = []
		for item: Dictionary in progress["items"]:
			totals[item["def_id"]] = int(totals.get(item["def_id"], 0)) - int(item["count"])
			saved[item["uid"]] = [item["def_id"], item["count"]]
			if int(item["container"]) == EQUIPMENT:
				weapons.append(int(item["slot"]))
		for def_id: String in totals:
			assert_eq(totals[def_id], 0, "S4: %s adds up in save %d" % [def_id, int(body["seq"])])
		assert_true(weapons.has(int(progress["active_weapon_slot"])), "S5: the active slot with a weapon (I10)")


func _audit_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for batch: Dictionary in _platform.sent(&"audit"):
		for entry: Dictionary in batch.get("entries", []):
			entries.append(entry)
	for entry: Dictionary in _platform.queued(&"audit"):
		entries.append(JSON.parse_string(JSON.stringify(entry)))
	return entries


func _audit_of(command: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for entry: Dictionary in _audit_entries():
		if entry.get("command") == command:
			found.append(entry)
	return found


func _audit_with_key(key: String) -> Dictionary:
	for entry: Dictionary in _audit_entries():
		if entry.get("key") == key:
			return entry
	return {}


# --- Give, split, merge and revert ----------------------------------------------------------------

func test_give_split_merge_and_revert_lower_the_total_by_what_was_given() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle(), "the kit of both, saved")
	var potions: int = _count(ana, POTION)
	var replies: PackedStringArray = await _gm(gema, "gm item_give Ana potion_health 5 regalo de prueba")
	var given: EconomyOp = _last_op(ana)
	if not assert_not_null(given, "one operation in Ana's journal"):
		return
	assert_eq(replies, PackedStringArray(["Dados 5 × potion_health a Ana (operación %d)." % given.op_id]))
	assert_eq(_count(ana, POTION), potions + 5, "five more")
	assert_eq([given.kind, given.actor_account_id, given.note], [EconomyOp.Kind.GM, 410, "regalo de prueba"])
	assert_eq(given.detail, {"command": "item_give", "args": ["42", "potion_health", "5"], "source": "gm",
			"actor_character_id": "41", "at_unix": NOW}, "the trail from §10, with the target by its character_id")
	var gift_uid: int = given.items[0].uid
	assert_eq([given.items.size(), given.items[0].count_delta, given.items[0].reason],
			[1, 5, EconomyReason.GM_GRANT], "a GM_GRANT of a new stack")
	var gift_slot: int = _player(ana).record.inventory.find_uid(gift_uid).y
	assert_true(await _settle(), "the GM's critical save")
	# Ana splits the stack into 3 and 2 and merges the 2 with the one from the kit.
	var free: int = _player(ana).record.inventory.first_free(BAG)
	_request(ana, InventoryOps.Op.SPLIT, BAG, gift_slot, BAG, free, 2, gift_uid)
	await _advance(2)
	var kit_slot: int = _bag_slot_of(ana, POTION, [gift_slot, free])
	var split: ItemInstance = _player(ana).record.inventory.get_item(BAG, free)
	if not assert_not_null(split, "the split stack") or not assert_true(kit_slot >= 0, "the kit's stack"):
		return
	_request(ana, InventoryOps.Op.MOVE, BAG, free, BAG, kit_slot, 0, split.uid)
	await _advance(2)
	assert_eq(_player(ana).record.inventory.get_item(BAG, gift_slot).count, 3, "3 in the given stack")
	assert_null(_player(ana).record.inventory.get_item(BAG, free), "the 2 have been merged")
	assert_eq(_count(ana, POTION), potions + 5, "splitting and merging do not change the total")
	assert_true(await _settle())
	# The reversal: the platform returns the saved operation.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, given.op_id))
	replies = await _gm(gema, "gm op_revert %d mal dado" % given.op_id, 2)
	var reversal: EconomyOp = _last_op(ana)
	if not assert_not_null(reversal, "the REVERSAL in the journal"):
		return
	assert_eq(replies, PackedStringArray(["Pedido al servicio de cuentas: operación %d para revertirla." % given.op_id,
			"Operación %d de Ana revertida (operación %d)." % [given.op_id, reversal.op_id]]))
	assert_eq(_count(ana, POTION), potions, "the total drops by 5: splitting or merging does not evade it")
	assert_eq([reversal.kind, reversal.ref_op_id, reversal.note, reversal.actor_account_id],
			[EconomyOp.Kind.REVERSAL, given.op_id, "mal dado", 410])
	var removed: int = 0
	for event: ItemEvent in reversal.items:
		assert_eq([event.reason, event.def_id], [EconomyReason.REVERSAL, POTION])
		removed += event.count_delta
	assert_eq(removed, -5, "five fewer with reason REVERSAL")
	assert_eq([reversal.items[0].uid, reversal.items[0].count_delta], [gift_uid, -3], "first from the given uid")
	var requests: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_PROGRESS_OP)
	assert_eq(requests.back().get("path"), "/internal/v1/ops/%d?zone_instance_id=%s" % [given.op_id,
			_platform.instance_id()], "the route with the instance")
	assert_true(await _settle(), "the REVERSAL's critical save")
	# In what was saved: the GM_GRANT, the REVERSAL and their ledger entries; in the audit, one entry per operation.
	var saved_gift: Dictionary = _saved_op(42, given.op_id)
	var saved_reversal: Dictionary = _saved_op(42, reversal.op_id)
	assert_eq(saved_gift["items"][0]["reason"], EconomyReason.GM_GRANT, "the saved GM_GRANT")
	assert_eq([int(saved_reversal["kind"]), saved_reversal["ref_op_id"]], [EconomyOp.Kind.REVERSAL,
			str(given.op_id)])
	assert_eq(saved_reversal["items"].size(), 2, "its two events")
	_assert_saves_accepted(42)
	_assert_saves_accepted(41)
	var gift_entry: Dictionary = _audit_with_key("op:%d" % given.op_id)
	var reversal_entry: Dictionary = _audit_with_key("op:%d" % reversal.op_id)
	assert_eq([gift_entry.get("command"), gift_entry.get("source"), gift_entry.get("actor_account_id"),
			gift_entry.get("actor_character_id"), gift_entry.get("target_character_id"),
			gift_entry.get("target_account_id")], ["item_give", "zone", "410", "41", "42", "420"])
	assert_eq(gift_entry.get("args"), {"args": ["42", "potion_health", "5"]}, "the args of the S8 row")
	assert_eq(int(gift_entry.get("at_unix", 0)), NOW, "the time from detail.at_unix")
	assert_eq([reversal_entry.get("command"), reversal_entry.get("target_character_id")], ["op_revert", "42"])
	assert_false(JSON.stringify(gift_entry).contains("Ana") or JSON.stringify(given.detail).contains("Ana"),
			"nor the target's name")
	assert_eq(_audit_of("op_revert").size(), 1, "op_revert with a platform leaves a single entry, that of its operation")
	# A second reversal, once the first is saved: the route says who reverted it.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, given.op_id, reversal.op_id))
	replies = await _gm(gema, "gm op_revert %d otra vez" % given.op_id, 2)
	assert_eq(replies[1] if replies.size() > 1 else "", "Esa operación ya está revertida.")
	assert_eq(_count(ana, POTION), potions, "nothing changes")
	assert_true(_player(ana).journal().is_empty(), "nor is another operation created")


func test_a_second_revert_before_the_first_is_saved_is_refused() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	var replies: PackedStringArray = await _gm(gema, "gm currency_add Ana oro +50 devolución del fallo 12")
	var gift: EconomyOp = _last_op(ana)
	if not assert_not_null(gift):
		return
	assert_eq(replies[0], "Oro de Ana: +50, queda en 50 (operación %d)." % gift.op_id)
	assert_eq(gift.ledger.size(), 1)
	assert_true(gift.ledger[0].equals(LedgerEntry.create(GOLD, 50, 50, EconomyReason.GM_GRANT, 0, 0)),
			"the GM_GRANT entry")
	assert_eq(gift.detail["args"], ["42", "oro", "50"])
	assert_true(await _settle())
	# Two at once: the second arrives while the first waits for the route.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, gift.op_id), 0.3)
	await _advance(60)
	var before: int = _system_texts(gema).size()
	for _i: int in 2:
		var message := NetMessages.ChatSend.new()
		message.channel = ChatChannel.Id.GM
		message.text = "gm op_revert %d error" % gift.op_id
		_receive(gema, message.encode())
	assert_eq(_system_texts(gema).slice(before), PackedStringArray([
			"Pedido al servicio de cuentas: operación %d para revertirla." % gift.op_id,
			"Esa operación ya se está revirtiendo."]), "the second, rejected")
	# The REVERSAL stays in flight: its save takes a while.
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 2.0)
	await _advance_until(func() -> bool: return _system_texts(gema).size() >= before + 3, 300)
	var reversal: EconomyOp = _last_op(ana)
	if not assert_not_null(reversal) or not assert_eq(reversal.kind, EconomyOp.Kind.REVERSAL):
		return
	assert_eq(_player(ana).record.wallets[GOLD], 0, "the gold goes back to 0")
	assert_eq(reversal.ledger.size(), 1)
	assert_true(reversal.ledger[0].equals(LedgerEntry.create(GOLD, -50, 0, EconomyReason.REVERSAL,
			LedgerEntry.RefKind.OP, gift.op_id)), "the opposite entry, with ref_kind 4 and the original")
	replies = await _gm(gema, "gm op_revert %d otra" % gift.op_id)
	assert_eq(replies[0], "Esa operación ya se está revirtiendo.", "the REVERSAL still unsaved")
	assert_eq(_platform.sent(PlatformEvent.KIND_PROGRESS_OP).size(), 1, "without requesting the route again")
	assert_true(await _settle())
	_assert_saves_accepted(42)
	# A balance that was already spent: nothing is reverted and what is missing is reported.
	await _gm(gema, "gm currency_add Ana oro 30 premio")
	var prize: EconomyOp = _last_op(ana)
	assert_true(await _settle())
	_server.console_command("currency_add Ana oro -20 gasto")
	assert_true(await _settle())
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, prize.op_id))
	replies = await _gm(gema, "gm op_revert %d no tocaba" % prize.op_id, 2)
	assert_eq(replies[1] if replies.size() > 1 else "", "A Ana le faltan 20 de oro: no se revierte nada.")
	assert_eq(_player(ana).record.wallets[GOLD], 10, "the balance does not change")
	assert_true(_player(ana).journal().is_empty(), "nor is the REVERSAL left")


# --- DEBUG_COMMAND with a platform ---------------------------------------------------------------------

func test_debug_commands_with_platform_need_admin() -> void:
	if not await _start(true):
		return
	var pablo: ServerPeer = await _join(1, 43, "Pablo")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	var ada: ServerPeer = await _join(3, 40, "Ada", &"admin")
	if pablo == null or pablo.entity == null or gema == null or gema.entity == null or ada.entity == null:
		return
	assert_true(await _settle())
	var saves: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	# 41 from a player: warning and the balance stays the same.
	var strikes: int = pablo.strikes_total
	_receive(pablo, NetMessages.DebugCommand.currency_add(GOLD, 100).encode())
	await _advance(2)
	assert_eq(pablo.strikes_total, strikes + 1, "41 without a role: warning")
	assert_eq(_player(pablo).record.wallets[GOLD], 0, "and the balance does not change")
	# 40 from a gm: also admin; neither item nor save.
	var potions: int = _count(gema, POTION)
	strikes = gema.strikes_total
	_receive(gema, NetMessages.DebugCommand.item_give(ItemDatabase.shared().net_id_of(POTION), 2).encode())
	await _advance(2)
	assert_eq(gema.strikes_total, strikes + 1, "40 from a gm: warning")
	assert_eq(_count(gema, POTION), potions, "nor an item")
	# The 16 from a gm: warning.
	_receive(gema, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_REFILL).encode())
	await _advance(2)
	assert_eq(gema.strikes_total, strikes + 2, "16 from a gm: warning")
	# The 5 and the 13 from a gm: also admin.
	var weapon := NetMessages.DebugCommand.simple(NetProtocol.DEBUG_SET_WEAPON)
	weapon.payload = PackedByteArray([0, 0])
	weapon.payload.encode_u16(0, CombatCatalog.weapon_id(&"bow"))
	_receive(gema, weapon.encode())
	_receive(gema, NetMessages.DebugCommand.cooldowns_off(true).encode())
	await _advance(2)
	assert_eq(gema.strikes_total, strikes + 4, "5 and 13 from a gm: warning")
	await _advance(30)
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), saves, "nothing to save")
	for peer: ServerPeer in [pablo, gema]:
		assert_true(_player(peer).journal().is_empty(), "nor operations of %s" % peer.display_name)
	# The admin: is missing a potion (the console removes it) and the 16 replenishes it with a "debug" GM.
	var uid: int = _player(ada).record.inventory.get_item(BAG, _bag_slot_of(ada, POTION)).uid
	assert_true(_server.console_command("item_take Ada %d 1 prueba" % uid).begins_with("Quitados 1 × potion_health"))
	var taken: EconomyOp = _last_op(ada)
	assert_eq([taken.detail["source"], taken.detail["actor_character_id"], taken.actor_account_id],
			["console", null, 0], "from the console, without an actor")
	assert_true(await _settle())
	var loadouts: int = _loadouts(ada)
	_receive(ada, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_REFILL).encode())
	await _advance(1)
	var refill: EconomyOp = _last_op(ada)
	if not assert_not_null(refill, "the 16 from an admin creates an operation"):
		return
	assert_eq([refill.kind, refill.note, refill.actor_account_id], [EconomyOp.Kind.GM, "debug", 400])
	assert_eq(refill.detail, {"command": "refill", "args": ["40"], "source": "debug", "actor_character_id": "40",
			"at_unix": NOW})
	assert_eq(refill.items.size(), 1)
	assert_eq([refill.items[0].def_id, refill.items[0].count_delta, refill.items[0].reason],
			[POTION, 1, EconomyReason.GM_GRANT], "a GM_GRANT for what is missing")
	assert_eq(_count(ada, POTION), 3, "replenished")
	assert_eq(_loadouts(ada), loadouts + 1, "and the LOADOUT to the owner, as always with the 16")
	assert_true(await _settle(), "the save accepts it")
	_assert_saves_accepted(40)
	var saved_refill: Dictionary = _saved_op(40, refill.op_id)
	assert_eq(saved_refill["items"][0]["uid"], null, "adds to the saved stack: the body does not carry its uid (S4)")
	# The 5 and the 13 from an admin: no operation and with their audit entry.
	_receive(ada, weapon.encode())
	_receive(ada, NetMessages.DebugCommand.cooldowns_off(true).encode())
	await _advance(2)
	assert_true(_player(ada).journal().is_empty(), "the 5 and the 13 do not create an operation")
	for command: String in ["set_weapon", "cooldowns_off"]:
		var entries: Array[Dictionary] = _audit_of(command)
		if assert_eq(entries.size(), 1, "one entry of %s" % command):
			assert_true(String(entries[0]["key"]).begins_with(_platform.instance_id() + ":"), "with its instance key")
			assert_eq(entries[0]["target_character_id"], "40")
	# And the 40 from an admin on themselves is valid.
	_receive(ada, NetMessages.DebugCommand.item_give(ItemDatabase.shared().net_id_of(STAMINA), 4).encode())
	await _advance(1)
	var give: EconomyOp = _last_op(ada)
	assert_eq([give.detail["command"], give.detail["args"], give.note], ["item_give", ["40", "potion_stamina", "4"],
			"debug"])
	assert_eq(_audit_with_key("op:%d" % give.op_id).get("command"), "item_give", "audited with its op:<op_id>")


# --- One's own characters, the fenced zone and the level -------------------------------------------

func test_own_characters_need_admin_even_in_dev() -> void:
	if not await _start(true, &"dev"):
		return
	var gema: ServerPeer = await _join(1, 41, "Gema", &"gm")
	var ada: ServerPeer = await _join(2, 40, "Ada", &"admin")
	if gema == null or gema.entity == null or ada == null or ada.entity == null:
		return
	assert_true(await _settle())
	var potions: int = _count(gema, POTION)
	var replies: PackedStringArray = await _gm(gema, "gm item_give Gema potion_health 1 para mí")
	assert_eq(replies[0], OWN, "a gm on their own character, in dev")
	assert_eq(_count(gema, POTION), potions)
	assert_true(_player(gema).journal().is_empty(), "no operation")
	# A console operation on Gema and its reversal by herself.
	assert_true(_server.console_command("currency_add Gema oro 7 prueba").begins_with("Oro de Gema: +7"))
	var gift: EconomyOp = _last_op(gema)
	assert_true(await _settle())
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(41, gift.op_id))
	replies = await _gm(gema, "gm op_revert %d me lo quito" % gift.op_id, 2)
	assert_eq(replies[1] if replies.size() > 1 else "", OWN, "op_revert on one's own, rejected")
	assert_eq(_player(gema).record.wallets[GOLD], 7)
	assert_true(_player(gema).journal().is_empty())
	# The admin can do it on their own.
	replies = await _gm(ada, "gm item_give Ada potion_health 1 para mí")
	assert_true(replies[0].begins_with("Dados 1 × potion_health a Ada"), replies[0])
	assert_true(await _settle())
	_assert_saves_accepted(40)


func test_a_fenced_zone_refuses_what_changes_something() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	_platform.set_fenced(true)
	var potions: int = _count(ana, POTION)
	var replies: PackedStringArray = await _gm(gema, "gm item_give Ana potion_health 2 regalo")
	assert_eq(replies[0], PLATFORM_DOWN, "item_give in a fenced zone")
	assert_eq(_count(ana, POTION), potions)
	assert_true(_player(ana).journal().is_empty(), "without creating the operation")
	assert_eq(_server.console_command("level_set Ana 3 prueba"), PLATFORM_DOWN, "not from the console either")
	assert_eq(_server.console_command("op_revert 5000 prueba"), PLATFORM_DOWN)
	assert_eq(_player(ana).record.level, 1)
	# Queries that ask nothing of the platform continue.
	assert_true(_server.console_command("inv_show Ana").begins_with("Inventario de Ana (personaje 42)"))
	_platform.set_fenced(false)
	replies = await _gm(gema, "gm item_give Ana potion_health 2 regalo")
	assert_true(replies[0].begins_with("Dados 2"), "outside the fence, yes")


func test_level_set_and_xp_add_leave_before_and_after_in_detail() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	var curve: LevelCurve = LevelCurve.shared()
	var replies: PackedStringArray = await _gm(gema, "gm level_set Ana 5 pruebas de nivel")
	var op: EconomyOp = _last_op(ana)
	if not assert_not_null(op):
		return
	assert_eq(replies[0], "Ana pasa del nivel 1 al 5 (%d de XP; operación %d)." % [curve.total_to(5), op.op_id])
	assert_eq(op.detail, {"command": "level_set", "args": ["42", "5"], "source": "gm", "actor_character_id": "41",
			"at_unix": NOW, "level_before": 1, "level_after": 5, "xp_before": 0, "xp_after": curve.total_to(5),
			"xp_delta": curve.total_to(5)}, "before and after, and at_unix")
	assert_true(op.is_empty(), "a GM with no ledger entries or events")
	assert_eq([_player(ana).record.level, ana.entity.level], [5, 5], "the level in the registry and on the entity")
	var level_ups: int = 0
	for bytes: PackedByteArray in _messages(ana, NetProtocol.MSG_ENTITY_EVENT):
		var decoded: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
		if decoded != null and decoded.event == NetMessages.EntityEvent.Kind.LEVEL_UP:
			level_ups += 1
	assert_eq(level_ups, 1, "its LEVEL_UP")
	assert_true(await _settle())
	# xp_add, as one more source; and lowering the level with level_set.
	replies = await _gm(gema, "gm xp_add Ana 100 más")
	op = _last_op(ana)
	assert_eq([op.detail["xp_before"], op.detail["xp_after"], op.detail["xp_delta"], op.detail["level_after"]],
			[curve.total_to(5), curve.total_to(5) + 100, 100, 5])
	replies = await _gm(gema, "gm level_set Ana 2 demasiado")
	op = _last_op(ana)
	assert_eq([op.detail["level_before"], op.detail["level_after"], op.detail["xp_delta"]],
			[5, 2, curve.total_to(2) - curve.total_to(5) - 100], "XP drops with a GM")
	assert_eq(ana.entity.level, 2)
	assert_true(await _settle())
	_assert_saves_accepted(42)
	var saved: Dictionary = _saves_of(42).back()["progress"]
	assert_eq([int(saved["level"]), int(saved["xp_total"])], [2, curve.total_to(2)])
	# Reverting the level_set subtracts its xp_delta.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, op.op_id))
	replies = await _gm(gema, "gm op_revert %d era bueno" % op.op_id, 2)
	assert_eq([_player(ana).record.level, _player(ana).record.xp_total], [5, curve.total_to(5) + 100],
			"goes back to where it was")
	assert_eq(ana.entity.level, 5)
	assert_true(await _settle())
	_assert_saves_accepted(42)


func test_reverting_merits_lowers_the_realm_points_too() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	# A PvP kill (aggregated, as on_merits pays it) and its saved GAMEPLAY.
	var player: PlayerProgress = _player(ana)
	player.gain_currency(Currency.Code.MERITS, 10, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 99)
	assert_eq(player.record.realm_points, 10, "I9: PvP merits raise the realm points")
	_server.get_saver().mark_critical(ana.entity.net_id, &"prueba")
	await _advance(2)
	assert_true(await _settle())
	var gameplay: Dictionary = (_saves_of(42).back()["progress"]["ops"] as Array).back()
	assert_eq(int(gameplay["kind"]), EconomyOp.Kind.GAMEPLAY)
	var op_id: int = ProgressJson.id_value(gameplay["op_id"])
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, op_id))
	var replies: PackedStringArray = await _gm(gema, "gm op_revert %d baja pactada" % op_id, 2)
	assert_true(replies.size() > 1 and replies[1].begins_with("Operación %d de Ana revertida" % op_id), str(replies))
	assert_eq([player.record.wallets[Currency.Code.MERITS], player.record.realm_points], [0, 0],
			"the merits and the realm points they gave, out")
	var reversal: EconomyOp = _last_op(ana)
	assert_true(reversal.ledger[0].equals(LedgerEntry.create(Currency.Code.MERITS, -10, 0, EconomyReason.REVERSAL,
			LedgerEntry.RefKind.OP, op_id)))
	assert_true(await _settle())
	assert_eq(int(_saves_of(42).back()["progress"]["realm_points"]), 0, "S6: the save with the points lowered")
	_assert_saves_accepted(42)


# --- Queries through the routes ---------------------------------------------------------------------

func test_ledger_show_and_op_show_through_the_routes() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	await _gm(gema, "gm currency_add Ana oro 50 primero")
	var first: EconomyOp = _last_op(ana)
	assert_true(await _settle())
	# Another not saved yet: the journal's one comes first, marked.
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 3.0)
	await _gm(gema, "gm currency_add Ana meritos 4 segundo")
	var second: EconomyOp = _last_op(ana)
	_platform.script_next(PlatformEvent.KIND_PROGRESS_LEDGER, 200, {"entries": [{"entry_id": "9", "op_id":
			str(first.op_id), "currency": GOLD, "seq": 1, "delta": 50, "balance_after": 50,
			"reason": EconomyReason.GM_GRANT, "ref_kind": 0, "ref_id": "0", "created_at_unix": NOW}]})
	var replies: PackedStringArray = await _gm(gema, "gm ledger_show Ana 5", 4)
	assert_eq(replies, PackedStringArray(["Pedido al servicio de cuentas: libro de Ana.",
			"Libro de Ana (personaje 42), 2 apuntes:",
			"op %d · méritos +4 → 4 (gm_grant) · sin guardar" % second.op_id,
			"op %d · oro +50 → 50 (gm_grant)" % first.op_id]))
	var request: Dictionary = _platform.sent(PlatformEvent.KIND_PROGRESS_LEDGER).back()
	assert_eq(request.get("path"), "/internal/v1/characters/42/ledger?limit=5&zone_instance_id=%s"
			% _platform.instance_id(), "the ledger route with its limit")
	# op_show of an unsaved one: from the journal, without asking for anything.
	replies = await _gm(gema, "gm op_show %d" % second.op_id, 2)
	assert_eq(replies[0], "Operación %d (gm) de personaje 42, actor 410, nota «segundo», comando currency_add, sin guardar."
			% second.op_id)
	assert_eq(_platform.sent(PlatformEvent.KIND_PROGRESS_OP).size(), 0)
	# op_show of a saved one, through the route; and one that does not exist.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, first.op_id))
	replies = await _gm(gema, "gm op_show %d" % first.op_id, 3)
	assert_eq(replies.slice(1), PackedStringArray([
			"Operación %d (gm) de personaje 42, actor 410, nota «primero», comando currency_add." % first.op_id,
			"Apunte: oro +50 → 50 (gm_grant)"]))
	replies = await _gm(gema, "gm op_show 999999", 2)
	assert_eq(replies[1] if replies.size() > 1 else "", "No hay ninguna operación 999999 de un personaje de esta zona.")
	# Queries are also audited, with the target by id.
	var entries: Array[Dictionary] = _audit_of("ledger_show")
	if assert_eq(entries.size(), 1):
		assert_eq([entries[0]["target_character_id"], entries[0]["args"]], ["42", {"args": ["42", "5"]}])
	assert_eq(_audit_of("op_show").size(), 3)
	assert_eq(_server.console_command("mastery_set Ana espada 3"), "No disponible hasta la fase 6.")


# --- Without a platform ---------------------------------------------------------------------------

func test_without_platform_everything_comes_from_the_journal() -> void:
	if not await _start(false):
		return
	var ana: ServerPeer = await _enter(1, null, "Ana")
	if ana == null or ana.entity == null:
		return
	var potions: int = _count(ana, POTION)
	var reply: String = _server.console_command("item_give Ana potion_health 20 prueba")
	var given: EconomyOp = _last_op(ana)
	if not assert_not_null(given):
		return
	assert_eq(reply, "Dados 20 × potion_health a Ana (operación %d)." % given.op_id)
	assert_eq(given.items.size(), 2, "new stacks of 15 and 5")
	assert_eq(given.detail["args"], ["0", "potion_health", "20"], "an ephemeral one has no character_id")
	assert_eq(_count(ana, POTION), potions + 20)
	assert_true(_server.console_command("inv_show Ana").contains("potion_health ×15"))
	assert_true(_server.console_command("op_show %d" % given.op_id).begins_with(
			"Operación %d (gm) de un efímero, nota «prueba», comando item_give." % given.op_id))
	# DEBUG_COMMAND without a platform: with --debug-commands, no role.
	_receive(ana, NetMessages.DebugCommand.currency_add(GOLD, 25).encode())
	await _advance(1)
	assert_eq(_player(ana).record.wallets[GOLD], 25)
	assert_true(_server.console_command("ledger_show Ana").contains("oro +25 → 25 (gm_grant)"))
	# Reverting from the journal; the second one, already reverted.
	reply = _server.console_command("op_revert %d sobraba" % given.op_id)
	assert_true(reply.begins_with("Operación %d de Ana revertida" % given.op_id), reply)
	assert_eq(_count(ana, POTION), potions)
	assert_eq(_server.console_command("op_revert %d otra" % given.op_id), "Esa operación ya está revertida.")
	var reversal: EconomyOp = _last_op(ana)
	assert_eq(_server.console_command("op_revert %d" % reversal.op_id), "Uso: op_revert <op_id> <motivo…>")
	assert_eq(_server.console_command("op_revert %d deshacer" % reversal.op_id),
			"Una operación de tipo REVERSAL no se revierte.")
	# item_take: the other weapon is removed; the only one left is not (I10).
	var equipment: InventoryState = _player(ana).record.inventory
	var active: ItemInstance = equipment.get_item(EQUIPMENT, 0)
	var other: ItemInstance = equipment.get_item(EQUIPMENT, 1)
	if other != null:
		assert_true(_server.console_command("item_take Ana %d quitar" % other.uid).begins_with("Quitados 1 × "),
				"the one from the slot that is not the active one")
		assert_null(equipment.get_item(EQUIPMENT, 1))
	if assert_not_null(active, "the kit's weapon"):
		assert_eq(_server.console_command("item_take Ana %d quitar" % active.uid),
				"Es la única arma de Ana: no se le puede quitar.")
	# The 16 without a platform is still the usual CAMP_REFILL (with no GM operation).
	var ops: int = _player(ana).journal().size()
	_receive(ana, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_REFILL).encode())
	await _advance(1)
	assert_eq(_player(ana).journal().size(), ops, "no operation")


# --- The base: the body's uids and undoing an operation -----------------------------------------

func test_body_event_uids_follow_what_the_platform_has() -> void:
	var ids := IdAllocator.new()
	ids.build_reserve = 2
	ids.add_block(1025, 1024)
	var record := ProgressRecord.new_character()
	record.starter_template_id = &"squire"
	var player := PlayerProgress.new(record, true, ids, ItemDatabase.shared())
	assert_true(player.grant_starter_kit(&"squire"))
	var first: Dictionary = player.build_section(1)
	for event: Dictionary in first["ops"][0]["items"]:
		assert_not_null(event["uid"], "the kit creates new uids: it carries them")
	player.acknowledge(1)
	var state: InventoryState = player.record.inventory
	var stack := Vector2i(-1, -1)
	for slot: int in range(state.bag_slots):
		if state.get_item(BAG, slot) != null and state.get_item(BAG, slot).def_id == POTION:
			stack = Vector2i(BAG, slot)
	if not assert_true(stack.x >= 0, "the kit's potions"):
		return
	var saved_uid: int = state.get_item(stack.x, stack.y).uid
	var context := InventoryOps.Context.new()
	# Split (new uid, unsaved) and destroy that half before the next save.
	var free: int = state.first_free(BAG)
	var split: InventoryOps.Outcome = player.apply_request(InventoryOps.make_request(InventoryOps.Op.SPLIT, BAG,
			stack.y, BAG, free, 1, saved_uid), context)
	assert_eq(split.result, InventoryOps.Result.OK, "SPLIT")
	var split_uid: int = state.get_item(BAG, free).uid
	assert_true(player.apply_request(InventoryOps.make_request(InventoryOps.Op.DESTROY, BAG, free,
			InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, split_uid), InventoryOps.Context.new()).is_ok())
	# A GM that adds to the saved stack and another that creates a new stack.
	var gm: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "prueba", {"command": "refill"})
	assert_true(player.op_add_items(gm, state.get_item(stack.x, stack.y).def_id, 1, EconomyReason.GM_GRANT).is_ok())
	assert_true(player.op_create_items(gm, &"potion_stamina", 2, EconomyReason.GM_GRANT).is_ok())
	var second: Dictionary = player.build_section(2)
	var destroy: Dictionary = second["ops"][0]
	assert_eq([destroy["kind"], destroy["items"][0]["uid"]], [EconomyOp.Kind.PLAYER, null],
			"the split half was not saved: no uid")
	assert_eq(second["ops"][1]["items"][0]["uid"], null, "adding to a saved one: no uid")
	assert_eq(second["ops"][1]["items"][1]["uid"], str(gm.items[1].uid), "the new stack does carry it")
	assert_eq(player.journal()[0].items[0].uid, split_uid, "the journal keeps the real uid")
	player.acknowledge(2)
	# What body 2 created is already saved: removing from it carries its uid.
	var take: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "prueba", {"command": "item_take"})
	assert_true(player.op_remove_items(take, &"potion_stamina", 1, EconomyReason.GM_REMOVE, gm.items[1].uid).is_ok())
	var third: Dictionary = player.build_section(3)
	assert_eq(third["ops"][0]["items"][0]["uid"], str(gm.items[1].uid))


func test_abort_op_undoes_the_whole_operation() -> void:
	var ids := IdAllocator.new()
	ids.build_reserve = 2
	ids.add_block(1025, 1024)
	var player := PlayerProgress.new(ProgressRecord.new_character(), true, ids, ItemDatabase.shared())
	assert_true(player.grant_starter_kit(&"marksman"))
	player.gain_currency(GOLD, 10, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC, 7)
	var inventory: InventoryState = player.record.inventory.duplicate_state()
	var revision: int = player.revision
	var op: EconomyOp = player.begin_op(EconomyOp.Kind.REVERSAL, 77, "prueba", {})
	var journal: int = player.journal().size()
	assert_true(player.change_currency(op, GOLD, -10, EconomyReason.REVERSAL, LedgerEntry.RefKind.OP, 5))
	assert_true(player.op_create_items(op, POTION, 20, EconomyReason.REVERSAL).is_ok())
	player.record.xp_total = 900
	player.record.level = 2
	assert_true(player.abort_op(op))
	assert_true(player.record.inventory.equals(inventory), "the inventory from before")
	assert_eq([player.record.wallets[GOLD], player.record.level, player.record.xp_total, player.revision],
			[10, 1, 0, revision], "balances, level, XP and revision from before")
	assert_eq(player.journal().size(), journal - 1, "the operation leaves the journal")
	assert_eq(player.journal().back().kind, EconomyOp.Kind.GAMEPLAY, "what it aggregated and closed stays")
	assert_false(player.abort_op(op), "once")
	# Removing without touching the protected slots.
	var state: InventoryState = player.record.inventory
	var weapon: ItemInstance = state.get_item(EQUIPMENT, 0)
	var protected: Array[Vector2i] = [Vector2i(EQUIPMENT, 0)]
	assert_eq(InventoryOps.count_outside(state, weapon.def_id, protected), 0)
	assert_eq(InventoryOps.remove_items(state.duplicate_state(), weapon.def_id, 1, EconomyReason.REVERSAL, weapon.uid,
			protected).result, InventoryOps.Result.STALE, "nor with its uid")
