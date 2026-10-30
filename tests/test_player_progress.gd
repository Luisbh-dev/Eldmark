extends TestCase
## Pruebas de [PlayerProgress] y de lo que usa (docs/progresion.md §4.5, §5.2, §8, §9.2 y §15 P5a): el kit de
## inicio (por plantilla y por defecto); la agregación (un apunte por moneda, motivo y referencia, y un evento sin
## uid por definición y motivo); el cierre de lo agregado antes de una operación suelta (S3 cuadra); la sección y su
## confirmación, también con un cuerpo en vuelo; los tres tramos de ids de [IdAllocator]; DESTROY con 256
## operaciones sin confirmar; ninguna reutilización de [CombatCatalog] llega a 30 s; el fin de un temporizador en
## hora Unix, entero y redondeado hacia arriba; [method PlayerProgress.is_dirty]; y [EconomyOp] y [LedgerEntry] en
## JSON, con los tipos de operación de las reglas exportadas.

const FIRST_ID: int = 1025
const NOW_UNIX: int = 1793282400
const HOLLOW_KEY: int = 3021413298

var _live: PlayerProgress.Live = null


func after_each() -> void:
	_live = null


# --- Ayudantes --------------------------------------------------------------------------------

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


## Un jugador con el kit del escudero ya confirmado (seq 1) y un cuerpo falso en [member _live].
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


# S3 de §13.3 sobre las operaciones de [param ops] (diccionarios de un cuerpo) desde [param start]: por moneda y en
# orden, balance_after = anterior + delta, en 0 … tope, con el signo de su motivo, y el último es el saldo de la foto.
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


# --- EconomyOp, LedgerEntry e IdAllocator ---------------------------------------------------------

func test_op_kinds_match_the_exported_rules() -> void:
	for kind_key: String in EconomyOp.Kind:
		assert_eq(ProgressionRulesExport.OP_KINDS.get(kind_key.to_lower(), -1), EconomyOp.Kind[kind_key],
				"EconomyOp.Kind.%s = op_kinds.%s" % [kind_key, kind_key.to_lower()])
	assert_eq(EconomyOp.kind_name(EconomyOp.Kind.STARTER_KIT), "starter_kit", "kind_name")
	for kind: int in EconomyOp.KIND_REASONS:
		for reason: int in EconomyOp.KIND_REASONS[kind]:
			assert_true(EconomyReason.is_known(reason), "motivo %d de %s" % [reason, EconomyOp.kind_name(kind)])


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
		# detail viaja tal cual: sus números vuelven como float, igual que los demás tras parse_string.
		original.detail = JSON.parse_string(JSON.stringify(original.detail))
		var data: Dictionary = JSON.parse_string(JSON.stringify(original.to_dictionary()))
		var back: EconomyOp = EconomyOp.from_dictionary(data)
		if assert_not_null(back, "%s se lee" % original):
			assert_true(back.equals(original), "%s campo a campo" % original)
			assert_true(back.is_consistent(), "con motivos de su tipo")
	var gameplay_data: Dictionary = gameplay.to_dictionary()
	assert_eq([gameplay_data["actor_account_id"], gameplay_data["ref_op_id"], gameplay_data["note"]],
			[null, null, null], "sin actor, referencia ni nota: null (§9.3)")
	assert_eq(gameplay_data["ledger"][0]["ref_id"], str(HOLLOW_KEY), "ref_id en cadena")
	assert_eq(gameplay_data["items"][0]["uid"], null, "el evento agregado, sin uid")
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
	assert_null(EconomyOp.from_dictionary(extra), "save_seq no viaja")
	var wrong_reason: EconomyOp = EconomyOp.create(7, EconomyOp.Kind.GAMEPLAY)
	wrong_reason.ledger.append(LedgerEntry.create(Currency.Code.GOLD, 5, 5, EconomyReason.GM_GRANT))
	assert_false(wrong_reason.is_consistent(), "GM_GRANT en una GAMEPLAY no cuadra (S2)")
	assert_false(EconomyOp.create(8, EconomyOp.Kind.GM, 77, " ").is_consistent(), "una GM sin nota no cuadra")


func test_id_allocator_tiers_and_blocks() -> void:
	var local: IdAllocator = IdAllocator.local()
	assert_eq([local.next_for_client(), local.next_for_server(), local.next_for_build()], [1, 2, 3],
			"sin plataforma, desde 1 y sin tramos")
	assert_false(local.needs_block(), "nunca pide bloques")
	var ids: IdAllocator = _ids(0, 4)
	var low: Array[int] = [0]
	ids.running_low.connect(func() -> void: low[0] += 1)
	assert_true(ids.needs_block(), "sin bloques, hay que pedir")
	assert_eq([ids.next_for_client(), ids.next_for_server(), ids.next_for_build()], [0, 0, 0], "sin ids, 0")
	ids.add_block(FIRST_ID, 4 + IdAllocator.SERVER_RESERVE + 2)
	assert_eq(ids.available(), 262, "262 ids")
	assert_eq([ids.next_for_client(), ids.next_for_client(), ids.next_for_client()], [1025, 1026, 0],
			"el cliente para con build_reserve + 256 libres")
	assert_eq(ids.next_for_server(), 1027, "el tramo del servidor")
	for _i: int in IdAllocator.SERVER_RESERVE - 1:
		ids.next_for_server()
	assert_eq(ids.next_for_server(), 0, "el servidor para con build_reserve libres")
	assert_eq([ids.next_for_build(), ids.next_for_build(), ids.next_for_build(), ids.next_for_build()],
			[1283, 1284, 1285, 1286], "los guardados toman los últimos")
	assert_eq(ids.next_for_build(), 0, "y sin ninguno, 0")
	assert_true(low[0] > 0, "running_low avisa")
	ids.add_block(5000, 10)
	ids.add_block(5005, 10)
	assert_eq(ids.available(), 10, "un bloque que se solapa se ignora")
	ids.add_block(0, 10)
	ids.add_block(IdAllocator.MAX_ID, 2)
	assert_eq(ids.available(), 10, "y uno fuera de 1 … 2^53 − 1")
	assert_eq(ids.next_for_build(), 5000, "el bloque nuevo, en orden")
	var two: IdAllocator = _ids(IdAllocator.BLOCK_SIZE, 128)
	two.add_block(FIRST_ID + IdAllocator.BLOCK_SIZE, IdAllocator.BLOCK_SIZE)
	assert_false(two.needs_block(), "con dos bloques no pide")
	assert_eq(two.next_for_client(), FIRST_ID, "gasta el primero")


# --- Kit --------------------------------------------------------------------------------------

func test_starter_kit_by_template_and_by_default() -> void:
	var squire: PlayerProgress = _player()
	assert_true(squire.grant_starter_kit(&"squire"), "el kit del escudero")
	assert_eq(_equipment(squire, 0).def_id, &"sword_shield_vado", "espada y escudo en WEAPON_1")
	assert_null(_equipment(squire, 1), "WEAPON_2 vacía")
	assert_eq([_bag(squire, 0).def_id, _bag(squire, 1).def_id, _bag(squire, 1).count, _bag(squire, 2).def_id,
			_bag(squire, 2).count], [&"bow_vado", &"potion_health", 3, &"potion_stamina", 2],
			"el arco y las pociones en la bolsa (§2.5)")
	assert_true(squire.record.starter_granted, "starter_granted")
	var journal: Array[EconomyOp] = squire.journal()
	if assert_eq(journal.size(), 1, "una operación STARTER_KIT"):
		assert_eq(journal[0].kind, EconomyOp.Kind.STARTER_KIT, "de tipo STARTER_KIT")
		assert_eq(journal[0].items.map(func(e: ItemEvent) -> Array: return [e.uid, e.def_id, e.count_delta]),
				[[1026, &"sword_shield_vado", 1], [1027, &"bow_vado", 1], [1028, &"potion_health", 3],
				[1029, &"potion_stamina", 2]], "un evento por instancia, con uid (op_id 1025)")
		assert_eq(journal[0].op_id, 1025, "op_id del tramo del servidor")
		assert_true(journal[0].is_consistent(), "motivos STARTER_KIT")
	assert_false(squire.grant_starter_kit(&"squire"), "no se da dos veces")
	assert_eq(squire.journal().size(), 1, "ni deja otra operación")
	var fallback: PlayerProgress = _player()
	fallback.record.starter_template_id = &"no_existe"
	assert_true(fallback.grant_starter_kit(fallback.record.starter_template_id), "con una plantilla que no existe")
	assert_eq([_equipment(fallback, 0).def_id, _equipment(fallback, 1).def_id], [&"bow_vado", &"sword_shield_vado"],
			"la primera elegible por id (marksman)")
	var starved: PlayerProgress = _player(_ids(130, 128))
	assert_false(starved.grant_starter_kit(&"squire"), "sin ids del servidor no hay kit")
	assert_false(starved.record.starter_granted, "starter_granted sigue false (llega en la siguiente entrada)")
	assert_true(starved.record.inventory.all_items().is_empty() and starved.journal().is_empty(), "y nada cambia")


# --- Agregación y diario ----------------------------------------------------------------------------

func test_aggregation_keeps_one_entry_per_currency_reason_and_reference() -> void:
	var player: PlayerProgress = _kitted()
	var start: PackedInt64Array = player.record.wallets.duplicate()
	for _i: int in 3:
		assert_eq(player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC,
				HOLLOW_KEY), 2, "+2 de oro de un Hueco")
	player.gain_currency(Currency.Code.MERITS, 30, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 88)
	player.gain_currency(Currency.Code.MERITS, 10, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 88)
	player.gain_currency(Currency.Code.MERITS, 5, EconomyReason.PVP_ASSIST, LedgerEntry.RefKind.CHARACTER, 88)
	player.gain_currency(Currency.Code.MERITS, 7, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 89)
	assert_eq(player.record.realm_points, 52, "los méritos de juego suben los puntos de reino (I9)")
	assert_true(player.lose_items(&"potion_health", 1, EconomyReason.CONSUME), "beber")
	assert_true(player.lose_items(&"potion_health", 1, EconomyReason.CONSUME), "beber otra")
	player.camp_refill()
	assert_eq(player.record.inventory.count_of(&"potion_health"), 3, "el campamento repone el total")
	assert_eq(player.unconfirmed_count(), 0, "lo agregado no va al diario al momento")
	assert_eq(player.pending_aggregate_count(), 6, "4 apuntes y 2 eventos agregados")
	var section: Dictionary = player.build_section(2)
	var ops: Array = section["ops"]
	if not assert_eq(ops.size(), 1, "una GAMEPLAY"):
		return
	assert_eq(int(ops[0]["kind"]), EconomyOp.Kind.GAMEPLAY, "de tipo GAMEPLAY")
	assert_eq((ops[0]["ledger"] as Array).map(func(e: Dictionary) -> Array:
			return [int(e["currency"]), int(e["delta"]), int(e["reason"]), int(e["ref_kind"]), e["ref_id"]]),
			[[1, 6, 6, 2, str(HOLLOW_KEY)], [2, 40, 3, 1, "88"], [2, 5, 4, 1, "88"], [2, 7, 3, 1, "89"]],
			"un apunte por (moneda, motivo, ref_kind, ref_id), en el orden en que llegaron")
	assert_eq(ops[0]["items"], [{"uid": null, "def_id": "potion_health", "count_delta": -2, "reason": 65},
			{"uid": null, "def_id": "potion_health", "count_delta": 2, "reason": 2}],
			"un evento sin uid por (definición, motivo)")
	assert_true(_ledger_squares(ops, start, section["wallets"]), "S3 cuadra")
	assert_eq(player.pending_aggregate_count(), 0, "lo agregado se ha cerrado")


func test_a_loose_op_closes_the_aggregate_first() -> void:
	var record: ProgressRecord = ProgressRecord.new_character()
	record.race_id = &"race_vardheim"
	record.wallets[Currency.Code.GOLD] = 100
	var player: PlayerProgress = _player(null, true, record)
	var start: PackedInt64Array = player.record.wallets.duplicate()
	player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC, HOLLOW_KEY)
	var gm: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "devolución", {"command": "currency_add",
			"source": "gm", "at_unix": NOW_UNIX})
	if not assert_not_null(gm, "la GM se abre"):
		return
	# Una ganancia que llega entre abrir la GM y apuntarla: se agrega detrás.
	player.gain_currency(Currency.Code.GOLD, 3, EconomyReason.OBJECTIVE, LedgerEntry.RefKind.FORTRESS, 77)
	assert_true(player.change_currency(gm, Currency.Code.GOLD, 50, EconomyReason.GM_GRANT, 0, 0), "+50 de un GM")
	assert_false(player.change_currency(gm, Currency.Code.GOLD, -1000, EconomyReason.GM_REMOVE, 0, 0),
			"un saldo negativo no se aplica")
	assert_false(player.change_currency(gm, Currency.Code.GOLD, 5, EconomyReason.GM_REMOVE, 0, 0),
			"ni un signo que no cuadra")
	var journal: Array[EconomyOp] = player.journal()
	if assert_eq(journal.size(), 2, "GAMEPLAY y GM"):
		assert_eq([journal[0].kind, journal[0].ledger[0].delta, journal[0].ledger[0].balance_after],
				[EconomyOp.Kind.GAMEPLAY, 2, 102], "primero lo agregado: +2, 102 (§5.2)")
		assert_eq([journal[1].kind, journal[1].ledger[0].delta, journal[1].ledger[0].balance_after],
				[EconomyOp.Kind.GM, 50, 152], "después la GM: +50, 152")
	var section: Dictionary = player.build_section(1)
	var ops: Array = section["ops"]
	assert_eq(ops.map(func(o: Dictionary) -> int: return int(o["kind"])), [2, 4, 2],
			"la ganancia del medio, en una GAMEPLAY detrás")
	assert_eq(int(ops[2]["ledger"][0]["balance_after"]), 155, "que sigue desde 152")
	assert_true(_ledger_squares(ops, start, section["wallets"]), "S3 cuadra")
	assert_eq(player.record.wallets[Currency.Code.GOLD], 155, "saldo 155")
	assert_false(player.add_items(gm, &"potion_health", 1, EconomyReason.GM_GRANT),
			"una operación que ya salió en un cuerpo no cambia")
	var empty: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "nada", {})
	assert_true(player.discard_op(empty), "una operación vacía se puede descartar")
	assert_eq(player.unconfirmed_count(), 3, "y no queda en el diario")


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
	assert_eq(keys, expected, "el registro sin campos de solo lectura y con ops (§9.3)")
	assert_eq(section["location"], _live.location, "la posición del cuerpo")
	assert_eq([section["health"], section["played_seconds"]], [640, 75], "su vida y el tiempo jugado")
	assert_eq(section["timers"], [{"key": "unstuck", "ends_at_unix": NOW_UNIX + 30}], "sin los vencidos")
	assert_eq((section["ops"] as Array).size(), 1, "el kit")
	assert_eq(player.journal()[0].save_seq, 1, "marcado con su seq")
	assert_eq((player.build_section(2)["ops"] as Array).size(), 0, "el siguiente no lo repite")
	player.acknowledge(1)
	assert_eq(player.unconfirmed_count(), 0, "confirmado, sale del diario")
	assert_eq(JSON.parse_string(JSON.stringify(section)).size(), section.size(), "se serializa")


func test_a_build_with_another_in_flight_does_not_repeat_its_ops() -> void:
	var player: PlayerProgress = _kitted()
	var first: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "a", {})
	player.change_currency(first, Currency.Code.GOLD, 10, EconomyReason.GM_GRANT, 0, 0)
	var n: Dictionary = player.build_section(5)
	var second: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "b", {})
	player.change_currency(second, Currency.Code.GOLD, 20, EconomyReason.GM_GRANT, 0, 0)
	var next: Dictionary = player.build_section(6)
	assert_eq((n["ops"] as Array).map(func(o: Dictionary) -> String: return o["op_id"]), [str(first.op_id)],
			"el cuerpo n lleva la primera")
	assert_eq((next["ops"] as Array).map(func(o: Dictionary) -> String: return o["op_id"]), [str(second.op_id)],
			"el n + 1 solo la segunda")
	player.acknowledge(5)
	assert_eq(player.journal(), [second] as Array[EconomyOp], "acknowledge(n) no quita las de n + 1")
	player.acknowledge(6)
	assert_eq(player.unconfirmed_count(), 0, "y acknowledge(n + 1) sí")


func test_three_id_tiers() -> void:
	# Con build_reserve libres: el servidor no toma ids, pero el guardado aún cierra lo agregado.
	var ids: IdAllocator = _ids(1024, 4)
	var player: PlayerProgress = _kitted(ids)
	while ids.available() > 4:
		if ids.available() > 4 + IdAllocator.SERVER_RESERVE:
			ids.next_for_client()
		else:
			ids.next_for_server()
	assert_eq(ids.available(), 4, "quedan build_reserve")
	player.lose_items(&"potion_health", 2, EconomyReason.CONSUME)
	player.lose_items(&"potion_stamina", 2, EconomyReason.CONSUME)
	var refill: InventoryOps.Outcome = player.camp_refill()
	assert_eq(player.record.inventory.count_of(&"potion_health"), 3, "la pila que queda se rellena")
	assert_eq(player.record.inventory.count_of(&"potion_stamina"), 0, "sin pila, CAMP_REFILL no abre una nueva")
	assert_false(refill.bag_full, "no es bolsa llena: espera al siguiente bloque")
	var request: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.SPLIT,
			InventoryState.ContainerId.BAG, 1, InventoryState.ContainerId.BAG, 10, 1, _bag(player, 1).uid)
	assert_eq(player.apply_request(request, InventoryOps.Context.new()).result, InventoryOps.Result.NOT_NOW,
			"SPLIT sin ids de los clientes: NOT_NOW")
	assert_null(player.begin_op(EconomyOp.Kind.GM, 77, "x", {}), "una GM no se abre")
	var section: Dictionary = player.build_section(2)
	assert_false(section.is_empty(), "build_section cierra lo agregado con el tramo de los guardados")
	assert_eq(ids.available(), 3, "con uno de los suyos")
	# Sin ninguno: {} y nada cambia.
	while ids.next_for_build() != 0:
		pass
	player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC, HOLLOW_KEY)
	var before: Array = [player.journal().size(), player.pending_aggregate_count(), player.record.wallets.duplicate(),
			player.record.location.duplicate()]
	_live.location["x"] = 50.0
	assert_eq(player.build_section(3), {}, "sin ids, {}")
	assert_eq([player.journal().size(), player.pending_aggregate_count(), player.record.wallets,
			player.record.location], before, "sin tocar nada")
	assert_true(player.is_dirty(), "y sigue sucio")
	ids.add_block(9000, 100)
	assert_false(player.build_section(3).is_empty(), "con un bloque nuevo, sale")


func test_destroy_with_256_unconfirmed_ops_is_not_now() -> void:
	var player: PlayerProgress = _kitted(_ids(4000, 128))
	for i: int in PlayerProgress.JOURNAL_LIMIT:
		var op: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "op %d" % i, {})
		player.change_currency(op, Currency.Code.GOLD, 1, EconomyReason.GM_GRANT, 0, 0)
	assert_eq(player.unconfirmed_count(), 256, "256 sin confirmar")
	var destroy: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.DESTROY,
			InventoryState.ContainerId.BAG, 1, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, _bag(player, 1).uid)
	var refused: InventoryOps.Outcome = player.apply_request(destroy, InventoryOps.Context.new())
	assert_eq(refused.result, InventoryOps.Result.NOT_NOW, "DESTROY → NOT_NOW")
	assert_eq(refused.changed, [Vector2i(0, 1)] as Array[Vector2i], "con la ranura que tocaba")
	assert_eq(player.record.inventory.count_of(&"potion_health"), 3, "nada cambia")
	player.build_section(2)
	player.acknowledge(2)
	var done: InventoryOps.Outcome = player.apply_request(destroy, InventoryOps.Context.new())
	assert_eq(done.result, InventoryOps.Result.OK, "confirmadas, sí")
	var journal: Array[EconomyOp] = player.journal()
	if assert_eq(journal.size(), 1, "una operación PLAYER"):
		assert_eq([journal[0].kind, journal[0].op_id], [EconomyOp.Kind.PLAYER, done.new_id],
				"con el id de la petición")
		assert_eq(journal[0].items.map(func(e: ItemEvent) -> Array: return [e.uid, e.count_delta, e.reason]),
				[[_bag(player, 1).uid, -1, EconomyReason.PLAYER_DESTROY]], "y su evento")
	var ephemeral: PlayerProgress = _kitted(IdAllocator.local(), false)
	for i: int in PlayerProgress.JOURNAL_LIMIT + 10:
		ephemeral.begin_op(EconomyOp.Kind.GM, 0, "op %d" % i, {})
	assert_eq(ephemeral.unconfirmed_count(), PlayerProgress.JOURNAL_LIMIT, "sin plataforma, las últimas 256")
	assert_eq(ephemeral.journal()[-1].note, "op 265", "las más nuevas")
	var ephemeral_destroy: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.DESTROY,
			InventoryState.ContainerId.BAG, 1, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, _bag(ephemeral, 1).uid)
	assert_eq(ephemeral.apply_request(ephemeral_destroy, InventoryOps.Context.new()).result, InventoryOps.Result.OK,
			"y DESTROY no tiene tope")


func test_destroy_closes_the_aggregate_before_its_player_op() -> void:
	var player: PlayerProgress = _kitted()
	player.lose_items(&"potion_health", 1, EconomyReason.CONSUME)
	var destroy: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.DESTROY,
			InventoryState.ContainerId.BAG, 2, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 0, _bag(player, 2).uid)
	assert_eq(player.apply_request(destroy, InventoryOps.Context.new()).result, InventoryOps.Result.OK, "DESTROY")
	assert_eq(player.journal().map(func(o: EconomyOp) -> int: return o.kind),
			[EconomyOp.Kind.GAMEPLAY, EconomyOp.Kind.PLAYER], "lo agregado, antes")


# --- Combate, temporizadores y suciedad --------------------------------------------------------------

func test_no_ability_or_consumable_lasts_thirty_seconds() -> void:
	var limit: int = 30 * PlayerProgress.TICKS_PER_SECOND
	var tables: CombatTables = CombatCatalog.tables()
	assert_true(tables.consumable_cooldown_ticks < limit,
			"la reutilización de los consumibles (%d ticks) no llega a 30 s" % tables.consumable_cooldown_ticks)
	for ability: AbilityTicks in tables.abilities:
		assert_true(ability.cooldown_ticks < limit, "%s (%d ticks) no llega a 30 s: si llega, hay que imponer su \
ability_ready al aparecer (§8)" % [ability.name, ability.cooldown_ticks])


func test_timer_end_is_an_integer_rounded_up() -> void:
	var s: int = 1000
	assert_eq(PlayerProgress.ends_at_unix_for(s + 1, s, NOW_UNIX), NOW_UNIX + 1, "1 tick: 1 s (ceili)")
	assert_eq(PlayerProgress.ends_at_unix_for(s + 60, s, NOW_UNIX), NOW_UNIX + 1, "60 ticks: 1 s")
	assert_eq(PlayerProgress.ends_at_unix_for(s + 61, s, NOW_UNIX), NOW_UNIX + 2, "61 ticks: 2 s")
	assert_eq(PlayerProgress.ends_at_unix_for(s + 18000, s, NOW_UNIX), NOW_UNIX + 300, "5 min")
	assert_eq(PlayerProgress.ends_at_unix_for(s - 30, s, NOW_UNIX), NOW_UNIX, "vencida: ahora")
	assert_eq(typeof(PlayerProgress.ends_at_unix_for(s + 61, s, NOW_UNIX)), TYPE_INT, "entero, no float")
	assert_eq(PlayerProgress.ready_tick_for(NOW_UNIX + 300, NOW_UNIX, s), s + 18000, "y de vuelta")
	assert_eq(PlayerProgress.ready_tick_for(NOW_UNIX - 5, NOW_UNIX, s), s, "una vencida, ya")


func test_is_dirty_with_moving_health_and_records() -> void:
	var player: PlayerProgress = _kitted()
	player.confirm_current()
	assert_false(player.is_dirty(), "recién confirmado")
	_live.played_seconds += 30
	assert_false(player.is_dirty(), "el tiempo jugado solo no ensucia")
	_live.location["x"] = 1.05
	assert_false(player.is_dirty(), "5 cm no es moverse")
	_live.location["x"] = 1.5
	assert_true(player.is_dirty(), "medio metro, sí")
	player.build_section(2)
	assert_true(player.is_dirty(), "construido pero sin confirmar, sigue sucio")
	player.acknowledge(2)
	assert_false(player.is_dirty(), "confirmado")
	_live.health = 900
	assert_true(player.is_dirty(), "perder vida ensucia")
	player.build_section(3)
	player.acknowledge(3)
	assert_false(player.is_dirty(), "confirmado otra vez")
	_live.active_weapon_slot = 1
	assert_false(player.is_dirty(), "la ranura 2 vacía: la activa que se guarda sigue siendo la 0 (I10)")
	player.add_xp(10, ProgressMessages.XpSource.NPC)
	assert_true(player.is_dirty(), "la XP ensucia")
	player.build_section(4)
	player.acknowledge(4)
	player.gain_currency(Currency.Code.GOLD, 1, EconomyReason.NPC_KILL, 0, 0)
	assert_true(player.is_dirty(), "lo agregado ensucia")


func test_charges_weapons_and_stashed_cooldowns() -> void:
	var player: PlayerProgress = _kitted()
	assert_eq(player.charges(), CombatState.pack_charges(3, 2), "3 de vida y 2 de resistencia")
	var extra: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "más", {})
	player.add_items(extra, &"potion_health", 20, EconomyReason.GM_GRANT)
	assert_eq(player.charges() & 0x0F, 15, "como mucho 15")
	assert_eq(player.weapons(), PackedInt32Array([CombatCatalog.weapon_id(&"sword_shield"), 0]),
			"la espada en la 1 y la 2 vacía")
	player.stash_ready(7, PackedInt64Array([100, 200, 300]))
	assert_eq(player.stashed_ready(7), PackedInt64Array([100, 200, 300]), "las reutilizaciones guardadas")
	assert_eq(player.stashed_ready(8), PackedInt64Array(), "las de otra arma, vacías")
