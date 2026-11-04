class_name SaveFixtures
extends RefCounted
## The shared cases for the save checks (docs/progresion.md §13.3): sequences of [code]progress[/code]
## sections with their expected result, valid and invalid (at least one per check, S1–S8), which
## the Go store test reads ([code]TestApply*[/code], progresion.md P7) and which
## [code]tests/test_progression_fixtures.gd[/code] regenerates so that they do not diverge. The valid sections come from
## [PlayerProgress] (the kit, drinking, refilling, earning gold and merits, XP, DESTROY, a GM action, a reversal...); the
## invalid ones, from changing a single thing in a valid one, so that only the expected check fails (the
## checks run in order: the first one that fails is the one recorded).
## [br][br]
## [b]How they are used[/b] (what the Go test does): each case starts in a fresh database with the accounts, the
## characters (created with [code]Create[/code], with their race, appearance and template) and the id blocks from
## [code]id_blocks[/code] (of [code]instance_id[/code] and of another instance); the clock is [code]now_unix[/code]. Each
## step is an [code]Apply[/code] of its [code]progress[/code] for its [code]character_id[/code] with
## [code]SaveKey{WorldID: world_id, InstanceID: instance_id, ZoneID: zone_id}[/code], in its own transaction;
## [code]expect[/code] is [code]"applied"[/code] (it commits) or the [code]check[/code] of the
## [code]*persistence.InvalidSaveError[/code] or of the database error of S8 (the transaction is rolled back).
## [br][br]
## [method build] is the only generator: [code]tools/progression/write_fixtures.gd[/code] writes the file and the
## test compares. No clock or randomness: two calls give the same result.

## Path of the cases file.
const OUTPUT_PATH: String = "res://tests/fixtures/progression/save_cases.json"
## Version of the file format.
const FORMAT: int = 1
## The platform time in all the steps.
const NOW_UNIX: int = 1793282400
const WORLD_ID: int = 1
const ZONE_ID: String = "vado_gris"
## The instance that saves ([code]claimed_by[/code]) and another in the same zone with its own block.
const INSTANCE_ID: String = "00000000-0000-4000-8000-0000000000f5"
const OTHER_INSTANCE_ID: String = "00000000-0000-4000-8000-0000000000f6"
const BLOCK_FIRST: int = 1025
const OTHER_BLOCK_FIRST: int = 3073
## When the two blocks were granted (S2 checks [code]detail.at_unix[/code] against this).
const BLOCK_GRANTED_AT_UNIX: int = NOW_UNIX - 600
## An id that falls in no block.
const OUTSIDE_ID: int = 5000
## The account and character of each one: the player (42, and the fictitious victim 88 belongs to nobody), the GM (41), the
## administrator (40) and another player (43 and 49).
const PLAYER_ACCOUNT: int = 7
const GM_ACCOUNT: int = 77
const ADMIN_ACCOUNT: int = 78
const OTHER_PLAYER_ACCOUNT: int = 9
const SEP: String = ", "


## A test character: its progress with a block from the instance, its fake body and the saves built.
class Flow:
	extends RefCounted
	var player: PlayerProgress
	var live: PlayerProgress.Live
	var seq: int = 0
	## The op_id of the GM action of [method play] (0 if there is none).
	var gm_op_id: int = 0

	func _init(template: StringName = &"squire") -> void:
		var ids := IdAllocator.new()
		ids.build_reserve = 128
		ids.add_block(SaveFixtures.BLOCK_FIRST, IdAllocator.BLOCK_SIZE)
		var record: ProgressRecord = ProgressRecord.new_character()
		record.race_id = &"race_vardheim"
		record.starter_template_id = template
		player = PlayerProgress.new(record, true, ids, ItemDatabase.shared())
		player.character_id = 42
		live = PlayerProgress.Live.new()
		live.location = {"zone_id": SaveFixtures.ZONE_ID, "channel": 0, "x": 12.5, "y": 0.0, "z": -40.25,
				"yaw": 1.5, "in_combat": false}
		live.played_seconds = 60
		live.now_unix = SaveFixtures.NOW_UNIX
		player.live_source = Callable(self, "_get_live")

	func _get_live() -> PlayerProgress.Live:
		return live

	## Builds and commits the next save: its progress section.
	func save() -> Dictionary:
		seq += 1
		var body: Dictionary = player.build_section(seq)
		player.acknowledge(seq)
		return body

	## The first entry: the kit (STARTER_KIT) with full health.
	func kit() -> Dictionary:
		player.grant_starter_kit(player.record.starter_template_id)
		return save()

	## A bit of play: drinking and refilling (CONSUME and CAMP_REFILL), gold from a Hollow and merits from a kill (a
	## GAMEPLAY with realm points), XP, DESTROY of a potion (PLAYER) and +50 gold from a GM (GM_GRANT).
	func play() -> Dictionary:
		live.played_seconds = 120
		live.health = 820
		player.lose_items(&"potion_health", 1, EconomyReason.CONSUME)
		player.camp_refill()
		player.gain_currency(Currency.Code.GOLD, 2, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC,
				HandoffTicket.zone_key_of("hollow"))
		player.gain_currency(Currency.Code.MERITS, 30, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 88)
		player.add_xp(30 * ProgressionRules.XP_PER_MERIT, ProgressMessages.XpSource.PVP)
		var stamina: ItemInstance = player.record.inventory.get_item(InventoryState.ContainerId.BAG, 2)
		player.apply_request(InventoryOps.make_request(InventoryOps.Op.DESTROY, InventoryState.ContainerId.BAG, 2,
				InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, stamina.uid), InventoryOps.Context.new())
		var gm: EconomyOp = player.begin_op(EconomyOp.Kind.GM, SaveFixtures.GM_ACCOUNT, "devolución del fallo 12",
				SaveFixtures.gm_detail("currency_add", ["42", "oro", "50"], 41))
		player.change_currency(gm, Currency.Code.GOLD, 50, EconomyReason.GM_GRANT, LedgerEntry.RefKind.NONE, 0)
		gm_op_id = gm.op_id
		return save()


## The cases: [code]{format, about, now_unix, world_id, zone_id, instance_id, id_blocks, accounts, characters,
## cases}[/code].
static func build() -> Dictionary:
	return {
		"format": FORMAT,
		"about": "Casos de las comprobaciones del guardado (docs/progresion.md §13.3), generados por "
				+ "tools/progression/write_fixtures.gd: cada caso en una base nueva; cada paso, un Apply en su "
				+ "transacción con expect applied o el check del error.",
		"now_unix": NOW_UNIX,
		"world_id": WORLD_ID,
		"zone_id": ZONE_ID,
		"instance_id": INSTANCE_ID,
		"id_blocks": [
			{"instance_id": INSTANCE_ID, "first": str(BLOCK_FIRST), "count": IdAllocator.BLOCK_SIZE,
					"granted_at_unix": BLOCK_GRANTED_AT_UNIX},
			{"instance_id": OTHER_INSTANCE_ID, "first": str(OTHER_BLOCK_FIRST), "count": IdAllocator.BLOCK_SIZE,
					"granted_at_unix": BLOCK_GRANTED_AT_UNIX},
		],
		"accounts": [
			{"account_id": str(PLAYER_ACCOUNT), "role": "player"},
			{"account_id": str(OTHER_PLAYER_ACCOUNT), "role": "player"},
			{"account_id": str(GM_ACCOUNT), "role": "gm"},
			{"account_id": str(ADMIN_ACCOUNT), "role": "admin"},
		],
		"characters": [
			_character(40, ADMIN_ACCOUNT),
			_character(41, GM_ACCOUNT),
			_character(42, PLAYER_ACCOUNT),
			_character(43, OTHER_PLAYER_ACCOUNT),
			_character(49, OTHER_PLAYER_ACCOUNT),
		],
		"cases": _cases(),
	}


## The text of the file: sorted keys, compact and with one case per line (so that a change shows in the diff),
## with a newline at the end.
static func to_json() -> String:
	var data: Dictionary = build()
	var keys: Array = data.keys()
	keys.sort()
	var lines: PackedStringArray = PackedStringArray()
	for key: String in keys:
		if key == "cases":
			var case_lines: PackedStringArray = PackedStringArray()
			for entry: Dictionary in data["cases"]:
				case_lines.append(JSON.stringify(entry, "", true))
			lines.append('"cases": [\n%s\n]' % ",\n".join(case_lines))
		else:
			lines.append("%s: %s" % [JSON.stringify(key), JSON.stringify(data[key], "", true)])
	return "{\n%s\n}\n" % ",\n".join(lines)


## The [code]detail[/code] of the trail of a GM command (§10) issued by the account of character
## [param actor_character_id] (0 = from the console, no actor).
static func gm_detail(command: String, args: Array, actor_character_id: int) -> Dictionary:
	var detail: Dictionary = {"command": command, "args": args.duplicate(), "at_unix": NOW_UNIX,
			"source": "gm" if actor_character_id != 0 else "console"}
	if actor_character_id != 0:
		detail["actor_character_id"] = str(actor_character_id)
	return detail


# --- Cases -------------------------------------------------------------------------------------

static func _character(character_id: int, account_id: int) -> Dictionary:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog,
			catalog.race_index(&"race_vardheim"))
	return {"character_id": str(character_id), "account_id": str(account_id), "realm": NetProtocol.Realm.VARDHEIM,
			"race_id": "race_vardheim", "appearance": Marshalls.raw_to_base64(appearance.encode()),
			"starter_template_id": "squire"}


static func _case(name: String, rule: String, steps: Array) -> Dictionary:
	var list: Array = []
	for step: Array in steps:
		list.append({"character_id": str(step[0]), "progress": step[1], "expect": step[2]})
	return {"name": name, "rule": rule, "steps": list}


# A copy of [param progress] changed by [param change] ([code](Dictionary) -> void[/code]).
static func _changed(progress: Dictionary, change: Callable) -> Dictionary:
	var copy: Dictionary = progress.duplicate(true)
	change.call(copy)
	return copy


static func _item(progress: Dictionary, def_id: String) -> Dictionary:
	for item: Dictionary in progress["items"]:
		if item["def_id"] == def_id:
			return item
	return {}


static func _op(progress: Dictionary, kind: int) -> Dictionary:
	for op: Dictionary in progress["ops"]:
		if int(op["kind"]) == kind:
			return op
	return {}


static func _wallet(progress: Dictionary, currency: int) -> Dictionary:
	for wallet: Dictionary in progress["wallets"]:
		if int(wallet["currency"]) == currency:
			return wallet
	return {}


static func _cases() -> Array:
	var cases: Array = []
	var flow := Flow.new()
	var kit: Dictionary = flow.kit()
	var play: Dictionary = flow.play()
	var ok: String = "applied"
	cases.append(_case("valid_kit_and_play", "El kit de la primera entrada (STARTER_KIT) y un rato de juego: GAMEPLAY "
			+ "agregada (CONSUME, CAMP_REFILL, oro de PNJ, méritos de PvP con puntos de reino), PLAYER (DESTROY) y GM",
			[[42, kit, ok], [42, play, ok]]))
	cases.append_array(_valid_cases(kit))
	cases.append_array(_s1_cases(kit, play))
	cases.append_array(_s2_cases(kit, play, flow.gm_op_id))
	cases.append_array(_s3_cases(kit, play))
	cases.append_array(_s4_cases(kit, play))
	cases.append_array(_s5_cases(kit, play))
	cases.append_array(_s6_cases(kit, play))
	cases.append_array(_s7_cases(kit, play))
	cases.append_array(_s8_cases(kit))
	return cases


static func _valid_cases(kit: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	# Moving, equipping and splitting leave no events; merging removes a uid without an event.
	var moves := Flow.new()
	var moves_kit: Dictionary = moves.kit()
	var bag: int = InventoryState.ContainerId.BAG
	var bow: ItemInstance = moves.player.record.inventory.get_item(bag, 0)
	var potion: ItemInstance = moves.player.record.inventory.get_item(bag, 1)
	moves.player.apply_request(InventoryOps.make_request(InventoryOps.Op.MOVE, bag, 0,
			InventoryState.ContainerId.EQUIPMENT, 1, 0, bow.uid), InventoryOps.Context.new())
	var split: InventoryOps.Outcome = moves.player.apply_request(InventoryOps.make_request(InventoryOps.Op.SPLIT,
			bag, 1, bag, 5, 1, potion.uid), InventoryOps.Context.new())
	var split_save: Dictionary = moves.save()
	moves.player.apply_request(InventoryOps.make_request(InventoryOps.Op.MOVE, bag, 5, bag, 1, 0, split.new_id),
			InventoryOps.Context.new())
	var merge_save: Dictionary = moves.save()
	cases.append(_case("valid_moves_split_merge", "Equipar el arco en WEAPON_2 y dividir una pila (uid nuevo sin "
			+ "evento); después juntarla otra vez (el uid se retira sin evento): S4 cuadra por definición",
			[[42, moves_kit, ok], [42, split_save, ok], [42, merge_save, ok]]))
	cases.append(_case("valid_timers", "Un temporizador vencido (un reintento tardío) y otro justo a 7 días: S7 los "
			+ "admite", [[42, _changed(kit, func(p: Dictionary) -> void: p["timers"] = [
				{"key": "capture:vado_gris_fort", "ends_at_unix": NOW_UNIX + 7 * 86400},
				{"key": "unstuck", "ends_at_unix": NOW_UNIX - 10}]), ok]]))
	# GM reversal (a single REVERSAL, with its actor and its detail).
	var reversal := Flow.new()
	var reversal_kit: Dictionary = reversal.kit()
	var reversal_play: Dictionary = reversal.play()
	var revert: EconomyOp = reversal.player.begin_op(EconomyOp.Kind.REVERSAL, GM_ACCOUNT, "devolución mal dada",
			gm_detail("op_revert", [str(reversal.gm_op_id), "devolución mal dada"], 41))
	revert.ref_op_id = reversal.gm_op_id
	reversal.player.change_currency(revert, Currency.Code.GOLD, -50, EconomyReason.REVERSAL, LedgerEntry.RefKind.OP,
			reversal.gm_op_id)
	var reversal_save: Dictionary = reversal.save()
	cases.append(_case("valid_reversal", "Una REVERSAL de la GM: apunte contrario con motivo REVERSAL, ref_kind 4 y la "
			+ "original como ref_id", [[42, reversal_kit, ok], [42, reversal_play, ok], [42, reversal_save, ok]]))
	# A GM action from the console: no actor and no actor_character_id.
	var console := Flow.new()
	var console_kit: Dictionary = console.kit()
	var console_gm: EconomyOp = console.player.begin_op(EconomyOp.Kind.GM, 0, "ajuste de la consola",
			gm_detail("currency_add", ["42", "oro", "5"], 0))
	console.player.change_currency(console_gm, Currency.Code.GOLD, 5, EconomyReason.GM_GRANT, 0, 0)
	cases.append(_case("valid_console_gm", "Una GM desde la consola: source console, sin actor_account_id ni "
			+ "actor_character_id", [[42, console_kit, ok], [42, console.save(), ok]]))
	# Lowering XP with a GM action (level_set) in the same save.
	var level := Flow.new()
	var level_kit: Dictionary = level.kit()
	var level_play: Dictionary = level.play()
	var level_detail: Dictionary = gm_detail("level_set", ["42", "1"], 41)
	level_detail.merge({"level_before": 1, "level_after": 1, "xp_before": level.player.record.xp_total, "xp_after": 0,
			"xp_delta": -level.player.record.xp_total})
	level.player.begin_op(EconomyOp.Kind.GM, GM_ACCOUNT, "nivel de prueba", level_detail)
	level.player.record.xp_total = 0
	level.player.record.level = 1
	cases.append(_case("valid_xp_down_with_gm", "xp_total baja con una GM (level_set, sin apuntes ni eventos) en el "
			+ "mismo guardado", [[42, level_kit, ok], [42, level_play, ok], [42, level.save(), ok]]))
	# An administrator on their own character.
	var admin := Flow.new()
	var admin_kit: Dictionary = admin.kit()
	var admin_gm: EconomyOp = admin.player.begin_op(EconomyOp.Kind.GM, ADMIN_ACCOUNT, "prueba propia",
			gm_detail("currency_add", ["40", "oro", "5"], 40))
	admin.player.change_currency(admin_gm, Currency.Code.GOLD, 5, EconomyReason.GM_GRANT, 0, 0)
	cases.append(_case("valid_admin_on_own_character", "Una GM de un admin sobre un personaje de su cuenta",
			[[40, admin_kit, ok], [40, admin.save(), ok]]))
	return cases


static func _s1_cases(kit: Dictionary, play: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	var rows: Array = [
		["s1_progress_format", "progress_format 2", func(p: Dictionary) -> void: p["progress_format"] = 2],
		["s1_unknown_key", "Una clave que no existe", func(p: Dictionary) -> void: p["mood"] = 1],
		["s1_read_only_race", "race_id es de solo lectura", func(p: Dictionary) -> void:
			p["race_id"] = "race_vardheim"],
		["s1_read_only_template", "starter_template_id es de solo lectura", func(p: Dictionary) -> void:
			p["starter_template_id"] = "squire"],
		["s1_saved_at_unix", "location.saved_at_unix es de solo lectura", func(p: Dictionary) -> void:
			p["location"]["saved_at_unix"] = NOW_UNIX],
		["s1_uid_as_number", "Un uid como número, no como cadena", func(p: Dictionary) -> void:
			_item(p, "bow_vado")["uid"] = 1027],
		["s1_op_id_too_large", "Un op_id de 2^53", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["op_id"] = "9007199254740992"],
		["s1_not_an_integer", "Un nivel que no es un número entero", func(p: Dictionary) -> void: p["level"] = 1.5],
		["s1_other_zone", "location.zone_id no es la zona de la instancia", func(p: Dictionary) -> void:
			p["location"]["zone_id"] = "test_world"],
	]
	for row: Array in rows:
		cases.append(_case(row[0], row[1], [[42, kit, ok], [42, _changed(play, row[2]), "S1"]]))
	return cases


static func _s2_cases(kit: Dictionary, play: Dictionary, gm_op_id: int) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	var rows: Array = [
		["s2_op_outside_blocks", "Un op_id que no cae en ningún bloque", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["op_id"] = str(OUTSIDE_ID)],
		["s2_op_of_another_instance", "Un op_id de un bloque de otra instancia", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["op_id"] = str(OTHER_BLOCK_FIRST + 7)],
		["s2_migration", "Una MIGRATION desde una zona", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GAMEPLAY)["kind"] = EconomyOp.Kind.MIGRATION],
		["s2_reason_of_another_kind", "Un GM_GRANT en una GAMEPLAY", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GAMEPLAY)["ledger"][0]["reason"] = EconomyReason.GM_GRANT],
		["s2_gm_without_note", "Una GM sin note", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["note"] = null],
		["s2_gm_by_a_player", "Una GM de una cuenta con rol player", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["actor_account_id"] = str(OTHER_PLAYER_ACCOUNT)
			_op(p, EconomyOp.Kind.GM)["detail"]["actor_character_id"] = "49"],
		["s2_gm_character_of_another_account", "detail.actor_character_id no es de la cuenta del actor",
			func(p: Dictionary) -> void: _op(p, EconomyOp.Kind.GM)["detail"]["actor_character_id"] = "42"],
		["s2_gm_from_the_future", "detail.at_unix más de 60 s por delante de ahora", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["detail"]["at_unix"] = NOW_UNIX + 120],
		["s2_gm_older_than_its_block", "detail.at_unix más de 60 s antes del granted_at de su bloque",
			func(p: Dictionary) -> void: _op(p, EconomyOp.Kind.GM)["detail"]["at_unix"] = BLOCK_GRANTED_AT_UNIX - 120],
		["s2_gm_without_at_unix", "Una GM sin detail.at_unix", func(p: Dictionary) -> void:
			(_op(p, EconomyOp.Kind.GM)["detail"] as Dictionary).erase("at_unix")],
		["s2_console_with_a_character", "source console con actor_character_id", func(p: Dictionary) -> void:
			_op(p, EconomyOp.Kind.GM)["actor_account_id"] = null
			_op(p, EconomyOp.Kind.GM)["detail"]["source"] = "console"],
	]
	for row: Array in rows:
		cases.append(_case(row[0], row[1], [[42, kit, ok], [42, _changed(play, row[2]), "S2"]]))
	cases.append(_case("s2_op_already_saved", "El mismo cuerpo otra vez como un guardado nuevo: sus op_id ya están "
			+ "en economy_ops", [[42, kit, ok], [42, play, ok], [42, play, "S2"]]))
	var second_kit: Dictionary = _changed(kit, func(p: Dictionary) -> void:
		var op: Dictionary = p["ops"][0]
		op["op_id"] = str(BLOCK_FIRST + 500)
		op["items"] = [{"uid": str(BLOCK_FIRST + 501), "def_id": "potion_health", "count_delta": 1,
				"reason": EconomyReason.STARTER_KIT}]
		p["items"].append({"uid": str(BLOCK_FIRST + 501), "def_id": "potion_health", "container": 0, "slot": 5,
				"count": 1, "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []}))
	cases.append(_case("s2_second_starter_kit", "Un STARTER_KIT con starter_granted ya true en la base",
			[[42, kit, ok], [42, second_kit, "S2"]]))
	# A GM on a character of their own account (admin only).
	var own := Flow.new()
	var own_kit: Dictionary = own.kit()
	var own_gm: EconomyOp = own.player.begin_op(EconomyOp.Kind.GM, GM_ACCOUNT, "prueba propia",
			gm_detail("currency_add", ["41", "oro", "5"], 41))
	own.player.change_currency(own_gm, Currency.Code.GOLD, 5, EconomyReason.GM_GRANT, 0, 0)
	cases.append(_case("s2_gm_on_own_character", "Una GM de un gm sobre un personaje de su cuenta",
			[[41, own_kit, ok], [41, own.save(), "S2"]]))
	# Reversals: two of the same one (in two saves and in one) and one of a REVERSAL.
	var flow := Flow.new()
	var flow_kit: Dictionary = flow.kit()
	var flow_play: Dictionary = flow.play()
	var revert: EconomyOp = flow.player.begin_op(EconomyOp.Kind.REVERSAL, GM_ACCOUNT, "devolución mal dada",
			gm_detail("op_revert", [str(flow.gm_op_id), "devolución mal dada"], 41))
	revert.ref_op_id = flow.gm_op_id
	flow.player.change_currency(revert, Currency.Code.GOLD, -50, EconomyReason.REVERSAL, LedgerEntry.RefKind.OP,
			flow.gm_op_id)
	var reverted: Dictionary = flow.save()
	var again: Dictionary = _changed(reverted, func(p: Dictionary) -> void:
		p["ops"][0]["op_id"] = str(BLOCK_FIRST + 600))
	cases.append(_case("s2_reversal_twice", "Una segunda REVERSAL de una operación ya revertida",
			[[42, flow_kit, ok], [42, flow_play, ok], [42, reverted, ok], [42, again, "S2"]]))
	var both: Dictionary = _changed(reverted, func(p: Dictionary) -> void:
		var copy: Dictionary = (p["ops"][0] as Dictionary).duplicate(true)
		copy["op_id"] = str(BLOCK_FIRST + 600)
		copy["ledger"][0]["balance_after"] = int(copy["ledger"][0]["balance_after"]) - 50
		p["ops"].append(copy))
	cases.append(_case("s2_reversal_twice_in_one_body", "Dos REVERSAL de la misma operación en un cuerpo",
			[[42, flow_kit, ok], [42, flow_play, ok], [42, both, "S2"]]))
	var of_reversal: Dictionary = _changed(reverted, func(p: Dictionary) -> void:
		var op: Dictionary = p["ops"][0]
		op["op_id"] = str(BLOCK_FIRST + 600)
		op["ref_op_id"] = reverted["ops"][0]["op_id"]
		op["ledger"][0]["delta"] = 50
		op["ledger"][0]["ref_id"] = reverted["ops"][0]["op_id"]
		_wallet(p, Currency.Code.GOLD)["balance"] = int(op["ledger"][0]["balance_after"]) + 100
		op["ledger"][0]["balance_after"] = int(op["ledger"][0]["balance_after"]) + 100)
	cases.append(_case("s2_reversal_of_a_reversal", "La REVERSAL de una REVERSAL",
			[[42, flow_kit, ok], [42, flow_play, ok], [42, reverted, ok], [42, of_reversal, "S2"]]))
	assert(gm_op_id > 0)
	return cases


static func _s3_cases(kit: Dictionary, play: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	cases.append(_case("s3_balance_after", "Un balance_after que no es el anterior más el delta", [[42, kit, ok],
			[42, _changed(play, func(p: Dictionary) -> void:
				_op(p, EconomyOp.Kind.GAMEPLAY)["ledger"][0]["balance_after"] = 3), "S3"]]))
	cases.append(_case("s3_final_balance", "El saldo de la foto no es el del último apunte", [[42, kit, ok],
			[42, _changed(play, func(p: Dictionary) -> void:
				_wallet(p, Currency.Code.GOLD)["balance"] = int(_wallet(p, Currency.Code.GOLD)["balance"]) + 1),
			"S3"]]))
	cases.append(_case("s3_balance_without_entries", "Una moneda que cambia sin apuntes", [[42, _changed(kit,
			func(p: Dictionary) -> void: _wallet(p, Currency.Code.GOLD)["balance"] = 10), "S3"]]))
	cases.append(_case("s3_sign", "Un GM_REMOVE con delta positivo", [[42, kit, ok], [42, _changed(play,
			func(p: Dictionary) -> void: _op(p, EconomyOp.Kind.GM)["ledger"][0]["reason"] = EconomyReason.GM_REMOVE),
			"S3"]]))
	cases.append(_case("s3_negative_balance", "Un saldo que quedaría negativo", [[42, kit, ok], [42, _changed(play,
			func(p: Dictionary) -> void:
				var entry: Dictionary = _op(p, EconomyOp.Kind.GM)["ledger"][0]
				entry["reason"] = EconomyReason.GM_REMOVE
				entry["delta"] = -100
				entry["balance_after"] = int(entry["balance_after"]) - 150
				_wallet(p, Currency.Code.GOLD)["balance"] = entry["balance_after"]), "S3"]]))
	return cases


static func _s4_cases(kit: Dictionary, play: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	cases.append(_case("s4_count_without_event", "Una pila que crece sin evento", [[42, kit, ok], [42, _changed(play,
			func(p: Dictionary) -> void: _item(p, "potion_health")["count"] = 4), "S4"]]))
	cases.append(_case("s4_item_disappears", "Un objeto que desaparece sin evento", [[42, kit, ok], [42,
			_changed(play, func(p: Dictionary) -> void: p["items"].erase(_item(p, "bow_vado"))), "S4"]]))
	cases.append(_case("s4_positive_event_of_a_known_uid", "Un evento con uid y count_delta > 0 de un uid que ya "
			+ "estaba en la base (los totales cuadran)", [[42, kit, ok], [42, _changed(play,
			func(p: Dictionary) -> void:
				var potion: Dictionary = _item(p, "potion_health")
				potion["count"] = int(potion["count"]) + 1
				_op(p, EconomyOp.Kind.GM)["items"].append({"uid": potion["uid"], "def_id": "potion_health",
						"count_delta": 1, "reason": EconomyReason.GM_GRANT})), "S4"]]))
	cases.append(_case("s4_negative_event_of_an_unknown_uid", "Un DESTROY de un uid que no estaba en la base",
			[[42, kit, ok], [42, _changed(play, func(p: Dictionary) -> void:
				_op(p, EconomyOp.Kind.PLAYER)["items"][0]["uid"] = str(BLOCK_FIRST + 700)), "S4"]]))
	return cases


static func _s5_cases(kit: Dictionary, play: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	var rows: Array = [
		["s5_duplicate_uid", "El mismo uid en dos ranuras (una pila partida sin uid nuevo)", func(p: Dictionary) -> void:
			var potion: Dictionary = _item(p, "potion_health")
			potion["count"] = int(potion["count"]) - 1
			var half: Dictionary = potion.duplicate(true)
			half["slot"] = 5
			half["count"] = 1
			p["items"].append(half)],
		["s5_container_2", "Un objeto en el banco (contenedor 2)", func(p: Dictionary) -> void:
			_item(p, "potion_stamina")["container"] = 2],
		["s5_slot_beyond_the_bag", "Una ranura de la bolsa por encima de bag_slots", func(p: Dictionary) -> void:
			_item(p, "potion_stamina")["slot"] = 30],
		["s5_same_slot", "Dos objetos en la misma ranura", func(p: Dictionary) -> void:
			_item(p, "potion_stamina")["slot"] = _item(p, "potion_health")["slot"]],
		["s5_unknown_definition", "Un objeto que no está en las reglas (creado con su evento)",
			func(p: Dictionary) -> void: _grant(p, "potion_mana", 1, BLOCK_FIRST + 800)],
		["s5_over_the_stack", "Una pila de 20 pociones (máximo 15), creada con su evento",
			func(p: Dictionary) -> void: _grant(p, "potion_health", 20, BLOCK_FIRST + 800)],
		["s5_durability", "Durabilidad en una poción", func(p: Dictionary) -> void:
			_item(p, "potion_stamina")["durability"] = 500],
		["s5_rarity", "Rareza 1 en la fase 5", func(p: Dictionary) -> void: _item(p, "potion_stamina")["rarity"] = 1],
		["s5_affixes", "Afijos en la fase 5", func(p: Dictionary) -> void: _item(p, "potion_stamina")["affixes"] = [3]],
		["s5_potion_equipped", "Una poción en el equipo", func(p: Dictionary) -> void:
			_item(p, "potion_stamina")["container"] = InventoryState.ContainerId.EQUIPMENT
			_item(p, "potion_stamina")["slot"] = 1],
		["s5_active_slot_without_weapon", "La ranura activa sin arma (I10)", func(p: Dictionary) -> void:
			p["active_weapon_slot"] = 1],
		["s5_swapped_definitions", "Dos uids que se cambian el def_id con los totales cuadrados",
			func(p: Dictionary) -> void:
				var health: Dictionary = _item(p, "potion_health")
				var stamina: Dictionary = _item(p, "potion_stamina")
				var health_uid: Variant = health["uid"]
				health["uid"] = stamina["uid"]
				stamina["uid"] = health_uid],
		["s5_unbound", "Un objeto ligado que deja de estarlo (I12)", func(p: Dictionary) -> void:
			_item(p, "sword_shield_vado")["bound"] = false],
		["s5_seed_changes", "Un uid que cambia de semilla (I1)", func(p: Dictionary) -> void:
			_item(p, "sword_shield_vado")["seed"] = "7"],
		["s5_new_uid_outside_blocks", "Un uid nuevo que no cae en ningún bloque (creado con su evento)",
			func(p: Dictionary) -> void: _grant(p, "potion_health", 1, OUTSIDE_ID)],
	]
	for row: Array in rows:
		cases.append(_case(row[0], row[1], [[42, kit, ok], [42, _changed(play, row[2]), "S5"]]))
	return cases


# A GM_GRANT of [param count] [param def_id] in a new stack [param uid] (slot 5), inside the body's GM action.
static func _grant(progress: Dictionary, def_id: String, count: int, uid: int) -> void:
	_op(progress, EconomyOp.Kind.GM)["items"].append({"uid": str(uid), "def_id": def_id, "count_delta": count,
			"reason": EconomyReason.GM_GRANT})
	progress["items"].append({"uid": str(uid), "def_id": def_id, "container": InventoryState.ContainerId.BAG,
			"slot": 5, "count": count, "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []})


static func _s6_cases(kit: Dictionary, play: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	var rows: Array = [
		["s6_level", "Un nivel que no es level_for(xp_total)", func(p: Dictionary) -> void: p["level"] = 2],
		["s6_realm_points", "Puntos de reino que no suben lo que los méritos de juego", func(p: Dictionary) -> void:
			p["realm_points"] = int(p["realm_points"]) + 1],
		["s6_bag_slots", "bag_slots cambia en la fase 5", func(p: Dictionary) -> void: p["bag_slots"] = 31],
		["s6_played_seconds_down", "played_seconds baja", func(p: Dictionary) -> void: p["played_seconds"] = 30],
		["s6_health_over_max", "Vida por encima de la máxima de las reglas", func(p: Dictionary) -> void:
			p["health"] = CombatCatalog.rules().health_max + 1],
	]
	for row: Array in rows:
		cases.append(_case(row[0], row[1], [[42, kit, ok], [42, _changed(play, row[2]), "S6"]]))
	var idle: Dictionary = _changed(play, func(p: Dictionary) -> void: p["ops"] = [])
	cases.append(_case("s6_xp_down", "xp_total baja sin una GM ni una REVERSAL", [[42, kit, ok], [42, play, ok],
			[42, _changed(idle, func(p: Dictionary) -> void: p["xp_total"] = int(p["xp_total"]) - 100), "S6"]]))
	cases.append(_case("s6_starter_granted_back", "starter_granted vuelve a false", [[42, kit, ok], [42, play, ok],
			[42, _changed(idle, func(p: Dictionary) -> void: p["starter_granted"] = false), "S6"]]))
	return cases


static func _s7_cases(kit: Dictionary, play: Dictionary) -> Array:
	var cases: Array = []
	var ok: String = "applied"
	var many: Array = []
	for i: int in ProgressRecord.MAX_TIMERS + 1:
		many.append({"key": "t%02d" % i, "ends_at_unix": NOW_UNIX + 60})
	var rows: Array = [
		["s7_key", "Una clave con mayúsculas y signos", func(p: Dictionary) -> void:
			p["timers"] = [{"key": "Unstuck!", "ends_at_unix": NOW_UNIX + 60}]],
		["s7_too_many", "17 temporizadores", func(p: Dictionary) -> void: p["timers"] = many.duplicate(true)],
		["s7_too_far", "Un fin a más de 7 días", func(p: Dictionary) -> void:
			p["timers"] = [{"key": "unstuck", "ends_at_unix": NOW_UNIX + 7 * 86400 + 1}]],
	]
	for row: Array in rows:
		cases.append(_case(row[0], row[1], [[42, kit, ok], [42, _changed(play, row[2]), "S7"]]))
	return cases


static func _s8_cases(kit: Dictionary) -> Array:
	var other: Dictionary = _changed(kit, func(p: Dictionary) -> void:
		p["ops"][0]["op_id"] = str(BLOCK_FIRST + 900))
	return [_case("s8_uid_of_another_character", "El kit de otro personaje con los mismos uid nuevos (otro op_id): "
			+ "S4 y S5 miran los de cada personaje, y la clave primaria de item_instances choca al insertar",
			[[42, kit, "applied"], [43, other, "S8"]])]
