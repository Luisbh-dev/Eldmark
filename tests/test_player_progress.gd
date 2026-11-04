extends TestCase
## Tests of [PlayerProgress] and of what it uses (docs/progression.md §4.5, §5.2, §8, §9.2 and §15 P5a): the
## starter kit (by template and by default); aggregation (one entry per currency, reason and reference, and a
## uid-less event per definition and reason); closing what has been aggregated before a standalone operation (S3
## adds up); the section and its acknowledgment, also with a body in flight; the three id ranges of [IdAllocator];
## DESTROY with 256 unacknowledged operations; no reuse delay of [CombatCatalog] reaches 30 s; the end of a timer
## in Unix time, an integer and rounded up; [method PlayerProgress.is_dirty]; and [EconomyOp] and [LedgerEntry]
## in JSON, with the operation types of the exported rules.

const FIRST_ID: int = 1025
const NOW_UNIX: int = 1793282400
const HOLLOW_KEY: int = 3021413298

var _live: PlayerProgress.Live = null


func after_each() -> void:
	_live = null


# --- Helpers ----------------------------------------------------------------------------------

func _ids(count: int = 1024, build_reserve: int = 128) -> IdAllocator:
	var ids := IdAllocator.new()
	ids.build_reserve = build_reserve
	if count > 0:
		ids.add_block(FIRST_ID, count)
	return ids


func _player(ids: IdAllocator = null, persistent: bool = true, record: ProgressRecord = null) -> PlayerProgress:
	if record == null:
		record = ProgressRecord.new_character()
		record.race_id = &"race_vardheim"
		record.starter_template_id = &"squire"
	var player := PlayerProgress.new(record, persistent, ids if ids != null else _ids(), ItemDatabase.shared())
	player.character_id = 42
	return player


## A player with the squire kit already acknowledged (seq 1) and a fake body in [member _live].
func _kitted(ids: IdAllocator = null, persistent: bool = true) -> PlayerProgress:
	var player: PlayerProgress = _player(ids, persistent)
	_live = PlayerProgress.Live.new()
	_live.location = {"zone_id": "vado_gris", "channel": 0, "x": 1.0, "y": 0.0, "z": 2.0, "yaw": 0.0,
			"in_combat": false}
	_live.now_unix = NOW_UNIX
	player.live_source = func() -> PlayerProgress.Live: return _live
	player.grant_starter_kit(&"squire")
	if not player.build_section(1).is_empty():
		player.acknowledge(1)
	return player


func _bag(player: PlayerProgress, slot: int) -> ItemInstance:
	return player.record.inventory.get_item(InventoryState.ContainerId.BAG, slot)


func _equipment(player: PlayerProgress, slot: int) -> ItemInstance:
	return player.record.inventory.get_item(InventoryState.ContainerId.EQUIPMENT, slot)


# S3 of §13.3 over the operations of [param ops] (single-body dictionaries) from [param start]: per currency and in
# order, balance_after = previous + delta, in 0 … cap, with the sign of its reason, and the last one is the snapshot's balance.
func _ledger_squares(ops: Array, start: PackedInt64Array, wallets: Array) -> bool:
	var balance: PackedInt64Array = start.duplicate()
	for op: Dictionary in ops:
		for entry: Dictionary in op["ledger"]:
			var currency: int = int(entry["currency"])
			if int(entry["balance_after"]) != balance[currency] + int(entry["delta"]):
				return false
			if not EconomyReason.sign_matches(int(entry["reason"]), int(entry["delta"])):
				return false
			balance[currency] = int(entry["balance_after"])
			if balance[currency] < 0 or balance[currency] > Currency.CAP:
				return false
	for wallet: Dictionary in wallets:
		if balance[int(wallet["currency"])] != int(wallet["balance"]):
			return false
	return true


# --- EconomyOp, LedgerEntry and IdAllocator -------------------------------------------------------

func test_op_kinds_match_the_exported_rules() -> void:
	for kind_key: String in EconomyOp.Kind:
		assert_eq(ProgressionRulesExport.OP_KINDS.get(kind_key.to_lower(), -1), EconomyOp.Kind[kind_key],
				"EconomyOp.Kind.%s = op_kinds.%s" % [kind_key, kind_key.to_lower()])
	assert_eq(EconomyOp.kind_name(EconomyOp.Kind.STARTER_KIT), "starter_kit", "kind_name")
	for kind: int in EconomyOp.KIND_REASONS:
		for reason: int in EconomyOp.KIND_REASONS[kind]:
			assert_true(EconomyReason.is_known(reason), "reason %d of %s" % [reason, EconomyOp.kind_name(kind)])


func test_economy_op_and_ledger_entry_round_trip_through_json() -> void:
	var op: EconomyOp = EconomyOp.create(5121, EconomyOp.Kind.GM, 77, "devolución del fallo 12",
			{"command": "currency_add", "source": "gm", "actor_character_id": "41", "at_unix": NOW_UNIX,
			"args": ["42", "oro", "50"]})
	op.ledger.append(LedgerEntry.create(Currency.Code.GOLD, 50, 152, EconomyReason.GM_GRANT))
	op.items.append(ItemEvent.create(2049, &"potion_health", 2, EconomyReason.GM_GRANT))
	var gameplay: EconomyOp = EconomyOp.create(5120, EconomyOp.Kind.GAMEPLAY)
	gameplay.ledger.append(LedgerEntry.create(Currency.Code.GOLD, 2, 102, EconomyReason.NPC_KILL,
			LedgerEntry.RefKind.NPC, HOLLOW_KEY))
	gameplay.items.append(ItemEvent.create(0, &"potion_health", -1, EconomyReason.CONSUME))
	for original: EconomyOp in [op, gameplay]:
		# detail travels as is: its numbers come back as float, like the others after parse_string.
		original.detail = JSON.parse_string(JSON.stringify(original.detail))
		var data: Dictionary = JSON.parse_string(JSON.stringify(original.to_dictionary()))
		var back: EconomyOp = EconomyOp.from_dictionary(data)
		if assert_not_null(back, "%s is read" % original):
			assert_true(back.equals(original), "%s field by field" % original)
			assert_true(back.is_consistent(), "with reasons of its type")
	var gameplay_data: Dictionary = gameplay.to_dictionary()
	assert_eq([gameplay_data["actor_account_id"], gameplay_data["ref_op_id"], gameplay_data["note"]],
			[null, null, null], "without actor, reference or note: null (§9.3)")
	assert_eq(gameplay_data["ledger"][0]["ref_id"], str(HOLLOW_KEY), "ref_id as a string")
	assert_eq(gameplay_data["items"][0]["uid"], null, "the aggregated event, without uid")
	var base: Dictionary = op.to_dictionary()
	var broken: Array = [
		["op_id como número", "op_id", 5121],
		["op_id 0", "op_id", "0"],
		["tipo 0", "kind", 0],
		["tipo 16", "kind", 16],
		["actor como número", "actor_account_id", 77],
		["nota de 201 caracteres", "note", "a".repeat(201)],
		["detail como lista", "detail", []],
		["un apunte roto", "ledger", [{"currency": 1, "delta": 0, "balance_after": 1, "reason": 7, "ref_kind": 0,
				"ref_id": "0"}]],
		["un apunte con el signo cambiado", "ledger", [{"currency": 1, "delta": -5, "balance_after": 1, "reason": 7,
				"ref_kind": 0, "ref_id": "0"}]],
		["un apunte de otra moneda", "ledger", [{"currency": 3, "delta": 5, "balance_after": 5, "reason": 7,
				"ref_kind": 0, "ref_id": "0"}]],
		["un apunte con ref_kind 5", "ledger", [{"currency": 1, "delta": 5, "balance_after": 5, "reason": 7,
				"ref_kind": 5, "ref_id": "0"}]],
		["un evento roto", "items", [{"uid": null, "def_id": "potion_health", "count_delta": 0, "reason": 65}]],
	]
	for entry: Array in broken:
		var data: Dictionary = base.duplicate(true)
		data[entry[1]] = entry[2]
		assert_null(EconomyOp.from_dictionary(data), entry[0])
	var extra: Dictionary = base.duplicate(true)
	extra["save_seq"] = 3
	assert_null(EconomyOp.from_dictionary(extra), "save_seq does not travel")
	var wrong_reason: EconomyOp = EconomyOp.create(7, EconomyOp.Kind.GAMEPLAY)
	wrong_reason.ledger.append(LedgerEntry.create(Currency.Code.GOLD, 5, 5, EconomyReason.GM_GRANT))
	assert_false(wrong_reason.is_consistent(), "GM_GRANT in a GAMEPLAY does not add up (S2)")
	assert_false(EconomyOp.create(8, EconomyOp.Kind.GM, 77, " ").is_consistent(), "a GM without a note does not add up")


func test_id_allocator_tiers_and_blocks() -> void:
	var local: IdAllocator = IdAllocator.local()
	assert_eq([local.next_for_client(), local.next_for_server(), local.next_for_build()], [1, 2, 3],
			"without a platform, from 1 and without ranges")
	assert_false(local.needs_block(), "never asks for blocks")
	var ids: IdAllocator = _ids(0, 4)
	var low: Array[int] = [0]
	ids.running_low.connect(func() -> void: low[0] += 1)
	assert_true(ids.needs_block(), "without blocks, it has to ask")
	assert_eq([ids.next_for_client(), ids.next_for_server(), ids.next_for_build()], [0, 0, 0], "without ids, 0")
	ids.add_block(FIRST_ID, 4 + IdAllocator.SERVER_RESERVE + 2)
	assert_eq(ids.available(), 262, "262 ids")
	assert_eq([ids.next_for_client(), ids.next_for_client(), ids.next_for_client()], [1025, 1026, 0],
			"the client stops at build_reserve + 256 free")
	assert_eq(ids.next_for_server(), 1027, "the server's range")
	for _i: int in IdAllocator.SERVER_RESERVE - 1:
		ids.next_for_server()
	assert_eq(ids.next_for_server(), 0, "the server stops at build_reserve free")
	assert_eq([ids.next_for_build(), ids.next_for_build(), ids.next_for_build(), ids.next_for_build()],
			[1283, 1284, 1285, 1286], "saves take the last ones")
	assert_eq(ids.next_for_build(), 0, "and with none, 0")
	assert_true(low[0] > 0, "running_low warns")
	ids.add_block(5000, 10)
	ids.add_block(5005, 10)
	assert_eq(ids.available(), 10, "an overlapping block is ignored")
	ids.add_block(0, 10)
	ids.add_block(IdAllocator.MAX_ID, 2)
	assert_eq(ids.available(), 10, "and one outside 1 … 2^53 − 1")
	assert_eq(ids.next_for_build(), 5000, "the new block, in order")
	var two: IdAllocator = _ids(IdAllocator.BLOCK_SIZE, 128)
	two.add_block(FIRST_ID + IdAllocator.BLOCK_SIZE, IdAllocator.BLOCK_SIZE)
	assert_false(two.needs_block(), "with two blocks it does not ask")
	assert_eq(two.next_for_client(), FIRST_ID, "spends the first")


# --- Kit --------------------------------------------------------------------------------------

func test_starter_kit_by_template_and_by_default() -> void:
	var squire: PlayerProgress = _player()
	assert_true(squire.grant_starter_kit(&"squire"), "the squire kit")
	assert_eq(_equipment(squire, 0).def_id, &"sword_shield_vado", "sword and shield in WEAPON_1")
	assert_null(_equipment(squire, 1), "WEAPON_2 empty")
	assert_eq([_bag(squire, 0).def_id, _bag(squire, 1).def_id, _bag(squire, 1).count, _bag(squire, 2).def_id,
			_bag(squire, 2).count], [&"bow_vado", &"potion_health", 3, &"potion_stamina", 2],
			"the bow and the potions in the bag (§2.5)")
	assert_true(squire.record.starter_granted, "starter_granted")
	var journal: Array[EconomyOp] = squire.journal()
	if assert_eq(journal.size(), 1, "a STARTER_KIT operation"):
		assert_eq(journal[0].kind, EconomyOp.Kind.STARTER_KIT, "of type STARTER_KIT")
		assert_eq(journal[0].items.map(func(e: ItemEvent) -> Array: return [e.uid, e.def_id, e.count_delta]),
				[[1026, &"sword_shield_vado", 1], [1027, &"bow_vado", 1], [1028, &"potion_health", 3],
				[1029, &"potion_stamina", 2]], "one event per instance, with uid (op_id 1025)")
		assert_eq(journal[0].op_id, 1025, "op_id of the server's range")
		assert_true(journal[0].is_consistent(), "STARTER_KIT reasons")
	assert_false(squire.grant_starter_kit(&"squire"), "it is not given twice")
	assert_eq(squire.journal().size(), 1, "nor does it leave another operation")
	var fallback: PlayerProgress = _player()
	fallback.record.starter_template_id = &"no_existe"
	assert_true(fallback.grant_starter_kit(fallback.record.starter_template_id), "with a template that does not exist")
	assert_eq([_equipment(fallback, 0).def_id, _equipment(fallback, 1).def_id], [&"bow_vado", &"sword_shield_vado"],
			"the first eligible by id (marksman)")
	var starved: PlayerProgress = _player(_ids(130, 128))
	assert_false(starved.grant_starter_kit(&"squire"), "without server ids there is no kit")
	assert_false(starved.record.starter_granted, "starter_granted is still false (arrives in the next entry)")
	assert_true(starved.record.inventory.all_items().is_empty() and starved.journal().is_empty(), "and nothing changes")


# --- Aggregation and journal ------------------------------------------------------------------

func test_aggregation_keeps_one_entry_per_currency_reason_and_reference() -> void:
	var player: PlayerProgress = _kitted()
	var start: PackedInt64Array = player.record.wallets.duplicate()
	for _i: int in 3:
		assert_eq(player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC,
				HOLLOW_KEY), 2, "+2 gold from a Hollow")
	player.gain_currency(Currency.Code.MERITS, 30, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 88)
	player.gain_currency(Currency.Code.MERITS, 10, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 88)
	player.gain_currency(Currency.Code.MERITS, 5, EconomyReason.PVP_ASSIST, LedgerEntry.RefKind.CHARACTER, 88)
	player.gain_currency(Currency.Code.MERITS, 7, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 89)
	assert_eq(player.record.realm_points, 52, "gameplay merits raise the realm points (I9)")
	assert_true(player.lose_items(&"potion_health", 1, EconomyReason.CONSUME), "drink")
	assert_true(player.lose_items(&"potion_health", 1, EconomyReason.CONSUME), "drink another")
	player.camp_refill()
	assert_eq(player.record.inventory.count_of(&"potion_health"), 3, "the camp refills the total")
	assert_eq(player.unconfirmed_count(), 0, "what is aggregated does not go to the journal immediately")
	assert_eq(player.pending_aggregate_count(), 6, "4 entries and 2 aggregated events")
	var section: Dictionary = player.build_section(2)
	var ops: Array = section["ops"]
	if not assert_eq(ops.size(), 1, "a GAMEPLAY"):
		return
	assert_eq(int(ops[0]["kind"]), EconomyOp.Kind.GAMEPLAY, "of type GAMEPLAY")
	assert_eq((ops[0]["ledger"] as Array).map(func(e: Dictionary) -> Array:
			return [int(e["currency"]), int(e["delta"]), int(e["reason"]), int(e["ref_kind"]), e["ref_id"]]),
			[[1, 6, 6, 2, str(HOLLOW_KEY)], [2, 40, 3, 1, "88"], [2, 5, 4, 1, "88"], [2, 7, 3, 1, "89"]],
			"one entry per (currency, reason, ref_kind, ref_id), in the order they arrived")
	assert_eq(ops[0]["items"], [{"uid": null, "def_id": "potion_health", "count_delta": -2, "reason": 65},
			{"uid": null, "def_id": "potion_health", "count_delta": 2, "reason": 2}],
			"a uid-less event per (definition, reason)")
	assert_true(_ledger_squares(ops, start, section["wallets"]), "S3 adds up")
	assert_eq(player.pending_aggregate_count(), 0, "what is aggregated has been closed")


func test_a_loose_op_closes_the_aggregate_first() -> void:
	var record: ProgressRecord = ProgressRecord.new_character()
	record.race_id = &"race_vardheim"
	record.wallets[Currency.Code.GOLD] = 100
	var player: PlayerProgress = _player(null, true, record)
	var start: PackedInt64Array = player.record.wallets.duplicate()
	player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC, HOLLOW_KEY)
	var gm: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "devolución", {"command": "currency_add",
			"source": "gm", "at_unix": NOW_UNIX})
	if not assert_not_null(gm, "the GM opens"):
		return
	# A gain that arrives between opening the GM and recording it: it is aggregated afterward.
	player.gain_currency(Currency.Code.GOLD, 3, EconomyReason.OBJECTIVE, LedgerEntry.RefKind.FORTRESS, 77)
	assert_true(player.change_currency(gm, Currency.Code.GOLD, 50, EconomyReason.GM_GRANT, 0, 0), "+50 de un GM")
	assert_false(player.change_currency(gm, Currency.Code.GOLD, -1000, EconomyReason.GM_REMOVE, 0, 0),
			"a negative balance is not applied")
	assert_false(player.change_currency(gm, Currency.Code.GOLD, 5, EconomyReason.GM_REMOVE, 0, 0),
			"nor a sign that does not match")
	var journal: Array[EconomyOp] = player.journal()
	if assert_eq(journal.size(), 2, "GAMEPLAY and GM"):
		assert_eq([journal[0].kind, journal[0].ledger[0].delta, journal[0].ledger[0].balance_after],
				[EconomyOp.Kind.GAMEPLAY, 2, 102], "first what is aggregated: +2, 102 (§5.2)")
		assert_eq([journal[1].kind, journal[1].ledger[0].delta, journal[1].ledger[0].balance_after],
				[EconomyOp.Kind.GM, 50, 152], "then the GM: +50, 152")
	var section: Dictionary = player.build_section(1)
	var ops: Array = section["ops"]
	assert_eq(ops.map(func(o: Dictionary) -> int: return int(o["kind"])), [2, 4, 2],
			"the gain in the middle, in a GAMEPLAY after it")
	assert_eq(int(ops[2]["ledger"][0]["balance_after"]), 155, "which continues from 152")
	assert_true(_ledger_squares(ops, start, section["wallets"]), "S3 adds up")
	assert_eq(player.record.wallets[Currency.Code.GOLD], 155, "balance 155")
	assert_false(player.add_items(gm, &"potion_health", 1, EconomyReason.GM_GRANT),
			"an operation that has already gone out in a body does not change")
	var empty: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "nada", {})
	assert_true(player.discard_op(empty), "an empty operation can be discarded")
	assert_eq(player.unconfirmed_count(), 3, "and does not stay in the journal")


func test_build_section_and_acknowledge() -> void:
	var player: PlayerProgress = _player()
	_live = PlayerProgress.Live.new()
	_live.location = {"zone_id": "vado_gris", "channel": 0, "x": 1.0, "y": 0.0, "z": 2.0, "yaw": 0.5,
			"in_combat": true}
	_live.health = 640
	_live.played_seconds = 75
	_live.now_unix = NOW_UNIX
	player.live_source = func() -> PlayerProgress.Live: return _live
	player.record.timers["unstuck"] = NOW_UNIX + 30
	player.record.timers["old"] = NOW_UNIX - 1
	player.grant_starter_kit(&"squire")
	var section: Dictionary = player.build_section(1)
	var keys: Array = section.keys()
	keys.sort()
	var expected: Array = Array(ProgressRecord.SAVE_KEYS) + ["ops"]
	expected.sort()
	assert_eq(keys, expected, "the record without read-only fields and with ops (§9.3)")
	assert_eq(section["location"], _live.location, "the body's position")
	assert_eq([section["health"], section["played_seconds"]], [640, 75], "its health and the time played")
	assert_eq(section["timers"], [{"key": "unstuck", "ends_at_unix": NOW_UNIX + 30}], "without the expired ones")
	assert_eq((section["ops"] as Array).size(), 1, "the kit")
	assert_eq(player.journal()[0].save_seq, 1, "marked with its seq")
	assert_eq((player.build_section(2)["ops"] as Array).size(), 0, "the next one does not repeat it")
	player.acknowledge(1)
	assert_eq(player.unconfirmed_count(), 0, "acknowledged, it leaves the journal")
	assert_eq(JSON.parse_string(JSON.stringify(section)).size(), section.size(), "it is serialized")


func test_a_build_with_another_in_flight_does_not_repeat_its_ops() -> void:
	var player: PlayerProgress = _kitted()
	var first: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "a", {})
	player.change_currency(first, Currency.Code.GOLD, 10, EconomyReason.GM_GRANT, 0, 0)
	var n: Dictionary = player.build_section(5)
	var second: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "b", {})
	player.change_currency(second, Currency.Code.GOLD, 20, EconomyReason.GM_GRANT, 0, 0)
	var next: Dictionary = player.build_section(6)
	assert_eq((n["ops"] as Array).map(func(o: Dictionary) -> String: return o["op_id"]), [str(first.op_id)],
			"body n carries the first")
	assert_eq((next["ops"] as Array).map(func(o: Dictionary) -> String: return o["op_id"]), [str(second.op_id)],
			"n + 1 only the second")
	player.acknowledge(5)
	assert_eq(player.journal(), [second] as Array[EconomyOp], "acknowledge(n) does not remove those of n + 1")
	player.acknowledge(6)
	assert_eq(player.unconfirmed_count(), 0, "and acknowledge(n + 1) does")


func test_three_id_tiers() -> void:
	# With build_reserve free: the server takes no ids, but the save still closes what is aggregated.
	var ids: IdAllocator = _ids(1024, 4)
	var player: PlayerProgress = _kitted(ids)
	while ids.available() > 4:
		if ids.available() > 4 + IdAllocator.SERVER_RESERVE:
			ids.next_for_client()
		else:
			ids.next_for_server()
	assert_eq(ids.available(), 4, "build_reserve remain")
	player.lose_items(&"potion_health", 2, EconomyReason.CONSUME)
	player.lose_items(&"potion_stamina", 2, EconomyReason.CONSUME)
	var refill: InventoryOps.Outcome = player.camp_refill()
	assert_eq(player.record.inventory.count_of(&"potion_health"), 3, "the remaining stack is refilled")
	assert_eq(player.record.inventory.count_of(&"potion_stamina"), 0, "without a stack, CAMP_REFILL does not open a new one")
	assert_false(refill.bag_full, "it is not a full bag: it waits for the next block")
	var request: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.SPLIT,
			InventoryState.ContainerId.BAG, 1, InventoryState.ContainerId.BAG, 10, 1, _bag(player, 1).uid)
	assert_eq(player.apply_request(request, InventoryOps.Context.new()).result, InventoryOps.Result.NOT_NOW,
			"SPLIT without client ids: NOT_NOW")
	assert_null(player.begin_op(EconomyOp.Kind.GM, 77, "x", {}), "a GM does not open")
	var section: Dictionary = player.build_section(2)
	assert_false(section.is_empty(), "build_section closes what is aggregated with the saves' range")
	assert_eq(ids.available(), 3, "with one of its own")
	# With none: {} and nothing changes.
	while ids.next_for_build() != 0:
		pass
	player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC, HOLLOW_KEY)
	var before: Array = [player.journal().size(), player.pending_aggregate_count(), player.record.wallets.duplicate(),
			player.record.location.duplicate()]
	_live.location["x"] = 50.0
	assert_eq(player.build_section(3), {}, "without ids, {}")
	assert_eq([player.journal().size(), player.pending_aggregate_count(), player.record.wallets,
			player.record.location], before, "without touching anything")
	assert_true(player.is_dirty(), "and it stays dirty")
	ids.add_block(9000, 100)
	assert_false(player.build_section(3).is_empty(), "with a new block, it goes out")


func test_destroy_with_256_unconfirmed_ops_is_not_now() -> void:
	var player: PlayerProgress = _kitted(_ids(4000, 128))
	for i: int in PlayerProgress.JOURNAL_LIMIT:
		var op: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "op %d" % i, {})
		player.change_currency(op, Currency.Code.GOLD, 1, EconomyReason.GM_GRANT, 0, 0)
	assert_eq(player.unconfirmed_count(), 256, "256 unacknowledged")
	var destroy: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.DESTROY,
			InventoryState.ContainerId.BAG, 1, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, _bag(player, 1).uid)
	var refused: InventoryOps.Outcome = player.apply_request(destroy, InventoryOps.Context.new())
	assert_eq(refused.result, InventoryOps.Result.NOT_NOW, "DESTROY → NOT_NOW")
	assert_eq(refused.changed, [Vector2i(0, 1)] as Array[Vector2i], "with the slot it was its turn for")
	assert_eq(player.record.inventory.count_of(&"potion_health"), 3, "nothing changes")
	player.build_section(2)
	player.acknowledge(2)
	var done: InventoryOps.Outcome = player.apply_request(destroy, InventoryOps.Context.new())
	assert_eq(done.result, InventoryOps.Result.OK, "acknowledged, yes")
	var journal: Array[EconomyOp] = player.journal()
	if assert_eq(journal.size(), 1, "a PLAYER operation"):
		assert_eq([journal[0].kind, journal[0].op_id], [EconomyOp.Kind.PLAYER, done.new_id],
				"with the request's id")
		assert_eq(journal[0].items.map(func(e: ItemEvent) -> Array: return [e.uid, e.count_delta, e.reason]),
				[[_bag(player, 1).uid, -1, EconomyReason.PLAYER_DESTROY]], "and its event")
	var ephemeral: PlayerProgress = _kitted(IdAllocator.local(), false)
	for i: int in PlayerProgress.JOURNAL_LIMIT + 10:
		ephemeral.begin_op(EconomyOp.Kind.GM, 0, "op %d" % i, {})
	assert_eq(ephemeral.unconfirmed_count(), PlayerProgress.JOURNAL_LIMIT, "without a platform, the last 256")
	assert_eq(ephemeral.journal()[-1].note, "op 265", "the newest ones")
	var ephemeral_destroy: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.DESTROY,
			InventoryState.ContainerId.BAG, 1, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, _bag(ephemeral, 1).uid)
	assert_eq(ephemeral.apply_request(ephemeral_destroy, InventoryOps.Context.new()).result, InventoryOps.Result.OK,
			"and DESTROY has no cap")


func test_destroy_closes_the_aggregate_before_its_player_op() -> void:
	var player: PlayerProgress = _kitted()
	player.lose_items(&"potion_health", 1, EconomyReason.CONSUME)
	var destroy: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.DESTROY,
			InventoryState.ContainerId.BAG, 2, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 0, _bag(player, 2).uid)
	assert_eq(player.apply_request(destroy, InventoryOps.Context.new()).result, InventoryOps.Result.OK, "DESTROY")
	assert_eq(player.journal().map(func(o: EconomyOp) -> int: return o.kind),
			[EconomyOp.Kind.GAMEPLAY, EconomyOp.Kind.PLAYER], "what is aggregated, first")


# --- Combat, timers and dirtiness ---------------------------------------------------------------

func test_no_ability_or_consumable_lasts_thirty_seconds() -> void:
	var limit: int = 30 * PlayerProgress.TICKS_PER_SECOND
	var tables: CombatTables = CombatCatalog.tables()
	assert_true(tables.consumable_cooldown_ticks < limit,
			"the consumables' reuse delay (%d ticks) does not reach 30 s" % tables.consumable_cooldown_ticks)
	for ability: AbilityTicks in tables.abilities:
		assert_true(ability.cooldown_ticks < limit, "%s (%d ticks) no llega a 30 s: si llega, hay que imponer su \
ability_ready al aparecer (§8)" % [ability.name, ability.cooldown_ticks])


func test_timer_end_is_an_integer_rounded_up() -> void:
	var s: int = 1000
	assert_eq(PlayerProgress.ends_at_unix_for(s + 1, s, NOW_UNIX), NOW_UNIX + 1, "1 tick: 1 s (ceili)")
	assert_eq(PlayerProgress.ends_at_unix_for(s + 60, s, NOW_UNIX), NOW_UNIX + 1, "60 ticks: 1 s")
	assert_eq(PlayerProgress.ends_at_unix_for(s + 61, s, NOW_UNIX), NOW_UNIX + 2, "61 ticks: 2 s")
	assert_eq(PlayerProgress.ends_at_unix_for(s + 18000, s, NOW_UNIX), NOW_UNIX + 300, "5 min")
	assert_eq(PlayerProgress.ends_at_unix_for(s - 30, s, NOW_UNIX), NOW_UNIX, "expired: now")
	assert_eq(typeof(PlayerProgress.ends_at_unix_for(s + 61, s, NOW_UNIX)), TYPE_INT, "integer, not float")
	assert_eq(PlayerProgress.ready_tick_for(NOW_UNIX + 300, NOW_UNIX, s), s + 18000, "and back")
	assert_eq(PlayerProgress.ready_tick_for(NOW_UNIX - 5, NOW_UNIX, s), s, "an expired one, now")


func test_is_dirty_with_moving_health_and_records() -> void:
	var player: PlayerProgress = _kitted()
	player.confirm_current()
	assert_false(player.is_dirty(), "just acknowledged")
	_live.played_seconds += 30
	assert_false(player.is_dirty(), "time played alone does not dirty")
	_live.location["x"] = 1.05
	assert_false(player.is_dirty(), "5 cm is not moving")
	_live.location["x"] = 1.5
	assert_true(player.is_dirty(), "half a meter, yes")
	player.build_section(2)
	assert_true(player.is_dirty(), "built but not acknowledged, still dirty")
	player.acknowledge(2)
	assert_false(player.is_dirty(), "acknowledged")
	_live.health = 900
	assert_true(player.is_dirty(), "losing health dirties")
	player.build_section(3)
	player.acknowledge(3)
	assert_false(player.is_dirty(), "acknowledged again")
	_live.active_weapon_slot = 1
	assert_false(player.is_dirty(), "slot 2 empty: the active one that is saved is still 0 (I10)")
	player.add_xp(10, ProgressMessages.XpSource.NPC)
	assert_true(player.is_dirty(), "XP dirties")
	player.build_section(4)
	player.acknowledge(4)
	player.gain_currency(Currency.Code.GOLD, 1, EconomyReason.NPC_KILL, 0, 0)
	assert_true(player.is_dirty(), "what is aggregated dirties")


func test_charges_weapons_and_stashed_cooldowns() -> void:
	var player: PlayerProgress = _kitted()
	assert_eq(player.charges(), CombatState.pack_charges(3, 2), "3 health and 2 stamina")
	var extra: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "más", {})
	player.add_items(extra, &"potion_health", 20, EconomyReason.GM_GRANT)
	assert_eq(player.charges() & 0x0F, 15, "at most 15")
	assert_eq(player.weapons(), PackedInt32Array([CombatCatalog.weapon_id(&"sword_shield"), 0]),
			"the sword in 1 and 2 empty")
	player.stash_ready(7, PackedInt64Array([100, 200, 300]))
	assert_eq(player.stashed_ready(7), PackedInt64Array([100, 200, 300]), "the saved reuse delays")
	assert_eq(player.stashed_ready(8), PackedInt64Array(), "those of another weapon, empty")
