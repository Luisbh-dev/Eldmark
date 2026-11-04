class_name ProgressCommands
extends RefCounted
## The GM commands for progression and economy (docs/progresion.md §10, P5d; PRG-16). They are registered by
## [method ProgressService.setup] in the [CommandRegistry]: through the console, through [code]/gm …[/code] with the
## role of the claim (all require [code]gm[/code]) and, the four with a network id (40 [code]item_give[/code], 41
## [code]currency_add[/code], 42 [code]level_set[/code] and 43 [code]xp_add[/code]), through DEBUG_COMMAND on the
## player's own character, which with the platform requires [code]admin[/code]. In phase 5 the character must be
## connected in this zone.
## [br][br]
## [b]Anything that changes something[/b] ([code]item_give[/code], [code]item_take[/code], [code]currency_add[/code],
## [code]level_set[/code], [code]xp_add[/code], [code]op_revert[/code] and the 16 [code]refill[/code] with a platform,
## which the zone calls) creates [b]a single operation[/b]: a GM one or, in [code]op_revert[/code], the REVERSAL, all or
## nothing ([method PlayerProgress.abort_op]), with the §10 trail (the actor, the mandatory [code]note[/code], "debug"
## for DEBUG_COMMAND, and the [code]detail[/code] with [code]command[/code], [code]args[/code] with the target by its
## [code]character_id[/code], [code]source[/code], [code]actor_character_id[/code] and [code]at_unix[/code], plus level
## and XP from before and after if it touches them), critical save [code]gm[/code], and its entry in the audit batch
## with the key [code]op:<op_id>[/code], the same fields and the same time as the row the save writes (S8). Beforehand:
## the rule of one's own characters (on a character of the sender's account, [code]admin[/code] only, with no
## exception per environment) and the fenced zone ("El servicio de cuentas no responde; inténtalo más tarde" (the
## accounts service is not responding; try again later), without creating anything).
## [br][br]
## [b]Queries[/b] ([code]inv_show[/code], [code]ledger_show[/code] and [code]op_show[/code]) are audited like any
## command; with a platform, [code]ledger_show[/code] and [code]op_show[/code] request the §13.2 routes and
## answer when the response arrives ([method on_platform_event]), through chat to whoever asked or to the log from the
## console. Without a platform (§9.4), everything comes from the session journal (the last 256 operations).
## [br][br]
## [b]Reversal[/b] ([code]op_revert[/code]): of an already saved operation (with a platform, the one from the route;
## without one, the one from the journal) of a character connected here, that is not a REVERSAL, a MIGRATION, nor one
## already reverted or currently being reverted. Opposite ledger entries (reason REVERSAL, [code]ref_kind[/code] 4), the
## realm points of merits with reason 3–5, what was given is removed (by the event's [code]uid[/code], from the bag and
## from an equipment slot that is not the active one), what was removed is created with other [code]uid[/code]s (copying
## the withdrawn row) and the XP from its [code]detail.xp_delta[/code] is subtracted. If anything is missing (they
## already spent it, the bag is full), nothing is reverted and what is missing is reported.

## Save criticality of every GM command that changes something (§9.2).
const CRITICAL_GM: StringName = &"gm"
## The [code]note[/code] of what arrives through DEBUG_COMMAND.
const NOTE_DEBUG: String = "debug"
## [code]detail.source[/code] (§10) depending on how the command arrives.
const SOURCE_GM: String = "gm"
const SOURCE_CONSOLE: String = "console"
const SOURCE_DEBUG: String = "debug"
## The [code]detail[/code] keys that S8 puts in their own column of [code]audit_log[/code]; the rest goes in the row's
## [code]args[/code] (and in the batch entry's).
const DETAIL_COLUMNS: Array[String] = ["command", "source", "actor_character_id", "at_unix"]
## [code]ledger_show[/code]: default and maximum number of entries ([code]limit[/code] of the route, §13.2).
const DEFAULT_LEDGER_ENTRIES: int = 20
const MAX_LEDGER_ENTRIES: int = 100
## Quantity of [code]item_give[/code] (that of id 40) and XP of [code]xp_add[/code] (that of 43).
const MAX_GIVE_COUNT: int = NetMessages.DebugCommand.MAX_ITEM_GIVE_COUNT
const MAX_XP_ADD: int = NetMessages.DebugCommand.MAX_XP_ADD
## Items per line in [code]inv_show[/code] (each chat line fits in one message).
const ITEMS_PER_LINE: int = 4
## Currencies of [code]currency_add[/code], without accents or capitals, and the word they carry in [code]args[/code].
const CURRENCY_WORDS: Dictionary[String, int] = {
	"oro": Currency.Code.GOLD, "gold": Currency.Code.GOLD, "meritos": Currency.Code.MERITS,
	"merits": Currency.Code.MERITS,
}
const CURRENCY_ARGS: Dictionary[int, String] = {Currency.Code.GOLD: "oro", Currency.Code.MERITS: "meritos"}

const TEXT_PLATFORM_DOWN: String = "El servicio de cuentas no responde; inténtalo más tarde."
const TEXT_OWN_CHARACTERS: String = "No puedes usarlo sobre tus personajes."
const TEXT_NOBODY: String = "No hay ningún jugador «%s» conectado en esta zona."
const TEXT_NO_IDS: String = "Ahora no hay ids para la operación; inténtalo en unos segundos."
const TEXT_NOT_SAVED: String = "Esa operación aún no está guardada; inténtalo en unos segundos."
const TEXT_REVERTING: String = "Esa operación ya se está revirtiendo."
const TEXT_REVERTED: String = "Esa operación ya está revertida."
const TEXT_NO_OP: String = "No hay ninguna operación %d de un personaje de esta zona."
const TEXT_NOT_HERE: String = "El personaje de la operación %d no está conectado en esta zona."
const TEXT_CANNOT_REVERT: String = "Una operación de tipo %s no se revierte."
const TEXT_NOTHING_TO_REVERT: String = "La operación %d no tiene nada que revertir."
const TEXT_BAD_ANSWER: String = "La respuesta del servicio de cuentas no se entiende."
const TEXT_MASTERY: String = "No disponible hasta la fase 6."
const TEXT_BUSY: String = "%s está en plena acción: ahora no se le puede tocar el equipo."
const TEXT_DEAD: String = "%s no está vivo."
const TEXT_BAG_FULL: String = "La bolsa de %s no tiene sitio."
const TEXT_NO_ITEM: String = "No existe el objeto «%s»."
const TEXT_NO_UID: String = "%s no tiene ningún objeto con uid %d."
const TEXT_ONLY_WEAPON: String = "Es la única arma de %s: no se le puede quitar."
const TEXT_SHORT_CURRENCY: String = "A %s le faltan %d de %s: no se revierte nada."
const TEXT_SHORT_ITEMS: String = "A %s le faltan %d × %s: no se revierte nada."
const TEXT_BALANCE: String = "%s tiene %d de %s: no se puede aplicar %+d."
const TEXT_SAME_LEVEL: String = "%s ya está en el nivel %d con %d de XP."
const TEXT_LEVEL_CAP: String = "%s ya está en el nivel máximo."
const TEXT_REQUESTED: String = "Pedido al servicio de cuentas: %s."


## Who sends a command and through where: the trail actor of §10.
class Actor:
	extends RefCounted
	## [enum CommandRegistry.Origin].
	var origin: int = CommandRegistry.Origin.CONSOLE
	## Who sends it (null from the console). The object is stored: a reply that arrives late knows who it was for.
	var peer: ServerPeer = null
	## The account, the character and the role of its claim (0 and empty from the console or without a platform).
	var account_id: int = 0
	var character_id: int = 0
	var role: StringName = &""
	## [code]detail.source[/code].
	var source: String = SOURCE_CONSOLE


## An operation for [code]op_show[/code] and [code]op_revert[/code]: the one from the §13.2 route or the one from the
## journal.
class OpView:
	extends RefCounted
	var op_id: int = 0
	var kind: int = 0
	var actor_account_id: int = 0
	var ref_op_id: int = 0
	var note: String = ""
	var detail: Dictionary = {}
	var created_at_unix: int = 0
	var participants: PackedInt64Array = PackedInt64Array()
	var reversed_by: int = 0
	## false: comes from a journal (not yet saved, or ephemeral).
	var saved: bool = true
	## [code]{character_id, currency, delta, balance_after, reason, ref_kind, ref_id}[/code].
	var ledger: Array[Dictionary] = []
	## [code]{character_id, uid, def_id, count_delta, reason}[/code] (uid 0 = aggregate).
	var items: Array[Dictionary] = []
	## The [code]item_instances[/code] rows of the uids of its events (also withdrawn ones), by uid.
	var instances: Dictionary[int, ItemInstance] = {}

	## The one for [param op], from the journal of character [param character_id].
	static func from_journal(op: EconomyOp, character_id: int) -> OpView:
		var view := OpView.new()
		view.op_id = op.op_id
		view.kind = op.kind
		view.actor_account_id = op.actor_account_id
		view.ref_op_id = op.ref_op_id
		view.note = op.note
		view.detail = op.detail.duplicate(true)
		view.participants = PackedInt64Array([character_id])
		view.saved = false
		for entry: LedgerEntry in op.ledger:
			view.ledger.append({"character_id": character_id, "currency": entry.currency, "delta": entry.delta,
					"balance_after": entry.balance_after, "reason": entry.reason, "ref_kind": entry.ref_kind,
					"ref_id": entry.ref_id})
		for event: ItemEvent in op.items:
			view.items.append({"character_id": character_id, "uid": event.uid, "def_id": event.def_id,
					"count_delta": event.count_delta, "reason": event.reason})
		return view

	## The one from the body of [code]GET /internal/v1/ops/{op_id}[/code] (§13.2, ids as strings); null if it does not fit.
	static func from_route(body: Dictionary) -> OpView:
		var data: Variant = body.get("op")
		if not data is Dictionary:
			return null
		var op: Dictionary = data
		var view := OpView.new()
		if not ProgressJson.is_id(op.get("op_id")) or not ProgressJson.is_int(op.get("kind"), 1, EconomyOp.MAX_KIND):
			return null
		view.op_id = ProgressJson.id_value(op["op_id"])
		view.kind = int(op["kind"])
		for key: String in ["actor_account_id", "ref_op_id", "reversed_by"]:
			var value: Variant = op.get(key)
			if value == null:
				continue
			if not ProgressJson.is_id(value):
				return null
			match key:
				"actor_account_id":
					view.actor_account_id = ProgressJson.id_value(value)
				"ref_op_id":
					view.ref_op_id = ProgressJson.id_value(value)
				_:
					view.reversed_by = ProgressJson.id_value(value)
		if op.get("note") is String:
			view.note = op["note"]
		if op.get("detail") is Dictionary:
			view.detail = (op["detail"] as Dictionary).duplicate(true)
		if ProgressJson.is_int(op.get("created_at_unix"), 0, ProgressJson.MAX_SAFE_INT):
			view.created_at_unix = int(op["created_at_unix"])
		for value: Variant in _array(op, "participants"):
			if not ProgressJson.is_id(value):
				return null
			view.participants.append(ProgressJson.id_value(value))
		for value: Variant in _array(op, "ledger"):
			var entry: Dictionary = value if value is Dictionary else {}
			if not ProgressJson.is_id(entry.get("character_id")) or not ProgressJson.is_int(entry.get("currency"), 1, 0xFF) \
					or not Currency.is_valid(int(entry["currency"])) \
					or not ProgressJson.is_int(entry.get("delta"), -Currency.CAP, Currency.CAP) \
					or not ProgressJson.is_int(entry.get("balance_after"), 0, Currency.CAP) \
					or not ProgressJson.is_int(entry.get("reason"), 1, 0xFF) \
					or not ProgressJson.is_int(entry.get("ref_kind"), 0, LedgerEntry.RefKind.OP) \
					or not ProgressJson.is_id(entry.get("ref_id"), 0):
				return null
			view.ledger.append({"character_id": ProgressJson.id_value(entry["character_id"]),
					"currency": int(entry["currency"]), "delta": int(entry["delta"]),
					"balance_after": int(entry["balance_after"]), "reason": int(entry["reason"]),
					"ref_kind": int(entry["ref_kind"]), "ref_id": ProgressJson.id_value(entry["ref_id"])})
		for value: Variant in _array(op, "items"):
			var event: Dictionary = value if value is Dictionary else {}
			var uid: Variant = event.get("uid")
			if not ProgressJson.is_id(event.get("character_id")) or (uid != null and not ProgressJson.is_id(uid)) \
					or not event.get("def_id") is String \
					or not ProgressJson.is_int(event.get("count_delta"), -0x7FFFFFFF, 0x7FFFFFFF) \
					or int(event["count_delta"]) == 0 or not ProgressJson.is_int(event.get("reason"), 1, 0xFF):
				return null
			view.items.append({"character_id": ProgressJson.id_value(event["character_id"]),
					"uid": ProgressJson.id_value(uid) if uid != null else 0, "def_id": StringName(event["def_id"]),
					"count_delta": int(event["count_delta"]), "reason": int(event["reason"])})
		for value: Variant in _array(op, "instances"):
			var row: Dictionary = value if value is Dictionary else {}
			var item: ItemInstance = _instance_of(row)
			if item != null:
				view.instances[item.uid] = item
		return view

	# An instances row (§13.2) as an ItemInstance; null if it does not fit.
	static func _instance_of(row: Dictionary) -> ItemInstance:
		var durability: Variant = row.get("durability")
		if not ProgressJson.is_id(row.get("uid")) or not row.get("def_id") is String \
				or not ProgressJson.is_int(row.get("rarity"), 0, ItemInstance.MAX_RARITY) \
				or not ProgressJson.is_bool(row.get("bound")) \
				or not ProgressJson.is_id(row.get("seed"), 0, ItemInstance.MAX_SEED) \
				or (durability != null and not ProgressJson.is_int(durability, 0, ItemInstance.MAX_DURABILITY)):
			return null
		var item := ItemInstance.new()
		item.uid = ProgressJson.id_value(row["uid"])
		item.def_id = StringName(row["def_id"])
		item.durability = int(durability) if durability != null else ItemInstance.NO_DURABILITY
		item.rarity = int(row["rarity"])
		item.bound = bool(row["bound"])
		item.seed = ProgressJson.id_value(row["seed"])
		for affix: Variant in _array(row, "affixes"):
			if ProgressJson.is_int(affix, 0, ItemInstance.MAX_AFFIX_ID):
				item.affixes.append(int(affix))
		return item

	static func _array(data: Dictionary, key: String) -> Array:
		return data[key] if data.get(key) is Array else []


# What a command that changes something says: whether it was done and the text for whoever sent it.
class _Reply:
	extends RefCounted
	var ok: bool = false
	var text: String = ""


var _service: WeakRef = null
var _zone: ZoneServer = null
var _platform: ZonePlatform = null
var _commands: CommandRegistry = null
var _db: ItemDatabase = null
## op_id → true while its op_revert waits for the platform's response.
var _pending_reverts: Dictionary[int, bool] = {}
var _stats: Dictionary[StringName, int] = {
	&"ops": 0, &"reversals": 0, &"refused": 0, &"forbidden_own": 0, &"fenced": 0, &"queries": 0,
	&"route_requests": 0, &"route_answers": 0,
}


func _init(service: ProgressService, zone: ZoneServer, platform: ZonePlatform) -> void:
	# No strong reference to the service, which is what holds this instance.
	_service = weakref(service)
	_zone = zone
	_platform = platform
	_db = ItemDatabase.shared()


## Registers the §10 commands in [param commands]: the ten console ones and [code]/gm[/code] with role
## [code]gm[/code] and, the four with a network id, [code]admin[/code] through DEBUG_COMMAND (§10).
func register_commands(commands: CommandRegistry) -> void:
	_commands = commands
	var gm: StringName = CommandRegistry.ROLE_GM
	var admin: StringName = CommandRegistry.ROLE_ADMIN
	commands.register(&"item_give", "item_give <jugador> <objeto> [cantidad] <motivo…>", _console_item_give,
			_net_item_give, gm, admin)
	commands.register(&"currency_add", "currency_add <jugador> <oro|meritos> <±cantidad> <motivo…>",
			_console_currency_add, _net_currency_add, gm, admin)
	commands.register(&"level_set", "level_set <jugador> <nivel> <motivo…>", _console_level_set, _net_level_set,
			gm, admin)
	commands.register(&"xp_add", "xp_add <jugador> <cantidad> <motivo…>", _console_xp_add, _net_xp_add, gm, admin)
	commands.register(&"item_take", "item_take <jugador> <uid> [cantidad] <motivo…>", _console_item_take,
			Callable(), gm)
	commands.register(&"mastery_set", "mastery_set <jugador> <arma> <nivel>", _console_mastery_set, Callable(), gm)
	commands.register(&"inv_show", "inv_show <jugador>", _console_inv_show, Callable(), gm)
	commands.register(&"ledger_show", "ledger_show <jugador> [n]", _console_ledger_show, Callable(), gm)
	commands.register(&"op_show", "op_show <op_id>", _console_op_show, Callable(), gm)
	commands.register(&"op_revert", "op_revert <op_id> <motivo…>", _console_op_revert, Callable(), gm)


## Counters for the report.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	return stats


## The responses of the §13.2 routes ([code]progress_op[/code] and [code]progress_ledger[/code]): that of an
## [code]op_show[/code], an [code]op_revert[/code] or a [code]ledger_show[/code] requested earlier.
func on_platform_event(event: PlatformEvent) -> void:
	_stats[&"route_answers"] += 1
	var context: Dictionary = event.context if event.context is Dictionary else {}
	var actor: Actor = context.get("actor") as Actor
	match String(context.get("purpose", "")):
		"op_show":
			_on_op_show(event, actor, int(context.get("op_id", 0)))
		"op_revert":
			_on_op_revert(event, actor, int(context.get("op_id", 0)), String(context.get("note", "")))
		"ledger_show":
			_on_ledger_show(event, actor, int(context.get("net_id", 0)), int(context.get("character_id", 0)),
					int(context.get("limit", DEFAULT_LEDGER_ENTRIES)))


# --- The 16 refill with a platform (§4.4) -----------------------------------------------------------

## The 16 through DEBUG_COMMAND with a platform and for whoever has an inventory (the zone calls it): a GM operation
## with a GM_GRANT for what is missing of each definition with [code]camp_refill[/code], [code]note[/code] "debug", and
## LOADOUT.
func net_refill(ctx: CommandRegistry.Context) -> int:
	var net_id: int = _net_target(ctx)
	if net_id == 0:
		return CommandRegistry.Result.REFUSED
	return _network_result(ctx, net_id, _refill(ctx, _actor_of(ctx), net_id, NOTE_DEBUG))


## [code]refill <jugador> <motivo…>[/code] through the console or [code]/gm[/code] with a platform for whoever has an
## inventory (the zone calls it with its [code]net_id[/code], already resolved): the same GM operation as the 16.
func console_refill(ctx: CommandRegistry.Context, net_id: int) -> String:
	var note: String = " ".join(ctx.args.slice(1)).strip_edges()
	if note.is_empty():
		return _usage(ctx, "refill <jugador> <motivo…>")
	return _refill(ctx, _actor_of(ctx), net_id, note).text


func _refill(ctx: CommandRegistry.Context, actor: Actor, net_id: int, note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	ctx.target = _entity(net_id)
	var args: Array = [_character_arg(player)]
	ctx.audit_args = {"args": args}
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	if not svc.is_alive(net_id):
		return _fail(TEXT_DEAD % name)
	var missing: Array[Array] = []
	for id: StringName in _db.all_ids():
		var definition: ItemDefinition = _db.get_definition(id)
		var lacking: int = definition.camp_refill - player.record.inventory.count_of(id)
		if definition.camp_refill > 0 and lacking > 0:
			missing.append([id, lacking])
	var s: int = _tick()
	if missing.is_empty():
		svc.after_gm_change(net_id, [], false, EconomyReason.GM_GRANT, s, true)
		return _done("A %s no le falta nada." % name)
	var op: EconomyOp = _begin(player, actor, EconomyOp.Kind.GM, note, "refill", args)
	if op == null:
		return _fail(TEXT_NO_IDS)
	var changed: Array[Vector2i] = []
	for entry: Array in missing:
		var outcome: InventoryOps.Outcome = player.op_add_items(op, entry[0], entry[1], EconomyReason.GM_GRANT)
		if not outcome.is_ok():
			player.abort_op(op)
			return _fail(TEXT_NO_IDS if outcome.result == InventoryOps.Result.NOT_NOW else TEXT_BAG_FULL % name)
		changed.append_array(outcome.changed)
	svc.after_gm_change(net_id, changed, false, EconomyReason.GM_GRANT, s, true)
	_commit(ctx, net_id, op)
	return _done("Pociones de %s repuestas (operación %d)." % [name, op.op_id])


# --- item_give (40) ----------------------------------------------------------------------------------

func _console_item_give(ctx: CommandRegistry.Context) -> String:
	var usage: String = _commands.get_usage(&"item_give")
	if ctx.args.size() < 3:
		return _usage(ctx, usage)
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	var definition: ItemDefinition = _db.get_definition(StringName(ctx.args[1]))
	if definition == null:
		return TEXT_NO_ITEM % ctx.args[1]
	var count: int = 1
	var first_note: int = 2
	if ctx.args[2].is_valid_int():
		count = ctx.args[2].to_int()
		first_note = 3
	var note: String = _note(ctx, first_note)
	if count < 1 or count > MAX_GIVE_COUNT or note.is_empty():
		return _usage(ctx, usage)
	return _item_give(ctx, _actor_of(ctx), net_id, definition, count, note).text


func _net_item_give(ctx: CommandRegistry.Context) -> int:
	var command: NetMessages.DebugCommand = _debug_command(NetProtocol.DEBUG_ITEM_GIVE, ctx.payload)
	var definition: ItemDefinition = _db.definition_by_net_id(command.get_item_net_id())
	var count: int = command.get_item_count()
	if definition == null or count < 1 or count > MAX_GIVE_COUNT:
		ctx.note = "objeto %d inexistente" % command.get_item_net_id() if definition == null else "cantidad %d" % count
		return CommandRegistry.Result.BAD_ARGUMENTS
	var net_id: int = _net_target(ctx)
	if net_id == 0:
		return CommandRegistry.Result.REFUSED
	return _network_result(ctx, net_id, _item_give(ctx, _actor_of(ctx), net_id, definition, count, NOTE_DEBUG))


# Creates count of definition in new stacks in the first free slots of the bag (GM_GRANT); bag full: nothing.
func _item_give(ctx: CommandRegistry.Context, actor: Actor, net_id: int, definition: ItemDefinition, count: int,
		note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	var args: Array = [_character_arg(player), String(definition.id), str(count)]
	ctx.audit_args = {"args": args}
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	var op: EconomyOp = _begin(player, actor, EconomyOp.Kind.GM, note, "item_give", args)
	if op == null:
		return _fail(TEXT_NO_IDS)
	var outcome: InventoryOps.Outcome = player.op_create_items(op, definition.id, count, EconomyReason.GM_GRANT)
	if not outcome.is_ok():
		player.abort_op(op)
		return _fail(TEXT_NO_IDS if outcome.result == InventoryOps.Result.NOT_NOW else TEXT_BAG_FULL % name)
	svc.after_gm_change(net_id, outcome.changed, false, EconomyReason.GM_GRANT, _tick())
	_commit(ctx, net_id, op)
	return _done("Dados %d × %s a %s (operación %d)." % [count, definition.id, name, op.op_id])


# --- item_take ---------------------------------------------------------------------------------------

func _console_item_take(ctx: CommandRegistry.Context) -> String:
	var usage: String = _commands.get_usage(&"item_take")
	if ctx.args.size() < 3 or not ProgressJson.is_id(ctx.args[1]):
		return _usage(ctx, usage)
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	var uid: int = ProgressJson.id_value(ctx.args[1])
	var count: int = 0
	var first_note: int = 2
	if ctx.args[2].is_valid_int():
		count = ctx.args[2].to_int()
		first_note = 3
		if count < 1:
			return _usage(ctx, usage)
	var note: String = _note(ctx, first_note)
	if note.is_empty():
		return _usage(ctx, usage)
	return _item_take(ctx, _actor_of(ctx), net_id, uid, count, note).text


# Destroys count (0: the whole stack) of the uid (GM_REMOVE). The only equipped weapon is not removed (I10).
func _item_take(ctx: CommandRegistry.Context, actor: Actor, net_id: int, uid: int, count: int,
		note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	var state: InventoryState = player.record.inventory
	var position: Vector2i = state.find_uid(uid)
	if position.x < 0:
		return _fail(TEXT_NO_UID % [name, uid])
	var item: ItemInstance = state.get_item(position.x, position.y)
	var amount: int = item.count if count == 0 else count
	var args: Array = [_character_arg(player), str(uid), str(amount)]
	ctx.audit_args = {"args": args}
	if amount > item.count:
		return _fail("Ese objeto de %s tiene %d." % [name, item.count])
	var equipment: int = InventoryState.ContainerId.EQUIPMENT
	var weapon_slot: bool = position.x == equipment and position.y < InventoryState.OPEN_EQUIPMENT_SLOTS
	if weapon_slot and position.y == svc.active_weapon_slot(net_id) \
			and state.get_item(equipment, 1 - position.y) == null:
		return _fail(TEXT_ONLY_WEAPON % name)
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	if weapon_slot and not svc.can_change_weapons(net_id):
		return _fail(TEXT_BUSY % name)
	var op: EconomyOp = _begin(player, actor, EconomyOp.Kind.GM, note, "item_take", args)
	if op == null:
		return _fail(TEXT_NO_IDS)
	var outcome: InventoryOps.Outcome = player.op_remove_items(op, item.def_id, amount, EconomyReason.GM_REMOVE, uid)
	if not outcome.is_ok():
		player.abort_op(op)
		return _fail(TEXT_NO_UID % [name, uid])
	svc.after_gm_change(net_id, outcome.changed, outcome.weapons_changed, EconomyReason.GM_REMOVE, _tick())
	_commit(ctx, net_id, op)
	return _done("Quitados %d × %s (uid %d) a %s (operación %d)." % [amount, item.def_id, uid, name, op.op_id])


# --- currency_add (41) -------------------------------------------------------------------------------

func _console_currency_add(ctx: CommandRegistry.Context) -> String:
	var usage: String = _commands.get_usage(&"currency_add")
	if ctx.args.size() < 4:
		return _usage(ctx, usage)
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	var currency: int = CURRENCY_WORDS.get(NameRules.normalize_key(ctx.args[1]), 0)
	var amount_text: String = ctx.args[2].trim_prefix("+")
	var note: String = _note(ctx, 3)
	if currency == 0 or not amount_text.is_valid_int() or note.is_empty():
		return _usage(ctx, usage)
	var amount: int = amount_text.to_int()
	if amount == 0 or absi(amount) > Currency.CAP:
		return _usage(ctx, usage)
	return _currency_add(ctx, _actor_of(ctx), net_id, currency, amount, note).text


func _net_currency_add(ctx: CommandRegistry.Context) -> int:
	var command: NetMessages.DebugCommand = _debug_command(NetProtocol.DEBUG_CURRENCY_ADD, ctx.payload)
	var currency: int = command.get_currency()
	var amount: int = command.get_currency_amount()
	if not Currency.is_valid(currency) or amount == 0:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var net_id: int = _net_target(ctx)
	if net_id == 0:
		return CommandRegistry.Result.REFUSED
	return _network_result(ctx, net_id, _currency_add(ctx, _actor_of(ctx), net_id, currency, amount, NOTE_DEBUG))


# A GM_GRANT or GM_REMOVE entry; a balance that would go negative or exceed the cap is not touched (§5.4).
func _currency_add(ctx: CommandRegistry.Context, actor: Actor, net_id: int, currency: int, amount: int,
		note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	var args: Array = [_character_arg(player), CURRENCY_ARGS[currency], str(amount)]
	ctx.audit_args = {"args": args}
	var balance: int = player.record.wallets[currency]
	if not CurrencyRules.can_apply(balance, amount):
		return _fail(TEXT_BALANCE % [name, balance, _currency_name(currency), amount])
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	var op: EconomyOp = _begin(player, actor, EconomyOp.Kind.GM, note, "currency_add", args)
	if op == null:
		return _fail(TEXT_NO_IDS)
	var reason: int = EconomyReason.GM_GRANT if amount > 0 else EconomyReason.GM_REMOVE
	if not player.change_currency(op, currency, amount, reason, LedgerEntry.RefKind.NONE, 0):
		player.abort_op(op)
		return _fail(TEXT_BALANCE % [name, balance, _currency_name(currency), amount])
	_commit(ctx, net_id, op)
	return _done("%s de %s: %+d, queda en %d (operación %d)." % [_currency_name(currency).capitalize(), name, amount,
			player.record.wallets[currency], op.op_id])


# --- level_set (42) and xp_add (43) ----------------------------------------------------------------------

func _console_level_set(ctx: CommandRegistry.Context) -> String:
	var usage: String = _commands.get_usage(&"level_set")
	if ctx.args.size() < 3 or not ctx.args[1].is_valid_int():
		return _usage(ctx, usage)
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	var level: int = ctx.args[1].to_int()
	var note: String = _note(ctx, 2)
	if level < 1 or level > LevelCurve.shared().level_cap or note.is_empty():
		return _usage(ctx, usage)
	return _level_set(ctx, _actor_of(ctx), net_id, level, note).text


func _net_level_set(ctx: CommandRegistry.Context) -> int:
	var level: int = _debug_command(NetProtocol.DEBUG_LEVEL_SET, ctx.payload).get_level()
	if level < 1 or level > LevelCurve.shared().level_cap:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var net_id: int = _net_target(ctx)
	if net_id == 0:
		return CommandRegistry.Result.REFUSED
	return _network_result(ctx, net_id, _level_set(ctx, _actor_of(ctx), net_id, level, NOTE_DEBUG))


# The level and xp_total = curve.total_to(level), in a GM operation with no entries or events, with before and after in
# detail.
func _level_set(ctx: CommandRegistry.Context, actor: Actor, net_id: int, level: int, note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	var args: Array = [_character_arg(player), str(level)]
	ctx.audit_args = {"args": args}
	var xp: int = LevelCurve.shared().total_to(level)
	var old_level: int = player.record.level
	var old_xp: int = player.record.xp_total
	if level == old_level and xp == old_xp:
		return _fail(TEXT_SAME_LEVEL % [name, level, xp])
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	var op: EconomyOp = _begin(player, actor, EconomyOp.Kind.GM, note, "level_set", args)
	if op == null:
		return _fail(TEXT_NO_IDS)
	player.record.level = level
	player.record.xp_total = xp
	if xp > old_xp:
		player.pending_xp_gain += xp - old_xp
		player.pending_xp_source = ProgressMessages.XpSource.GM
	_xp_detail(op, old_level, old_xp, player)
	_svc().after_level_change(net_id, old_level, _tick())
	_commit(ctx, net_id, op)
	return _done("%s pasa del nivel %d al %d (%d de XP; operación %d)." % [name, old_level, level, xp, op.op_id])


func _console_xp_add(ctx: CommandRegistry.Context) -> String:
	var usage: String = _commands.get_usage(&"xp_add")
	if ctx.args.size() < 3 or not ctx.args[1].is_valid_int():
		return _usage(ctx, usage)
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	var amount: int = ctx.args[1].to_int()
	var note: String = _note(ctx, 2)
	if amount < 1 or amount > MAX_XP_ADD or note.is_empty():
		return _usage(ctx, usage)
	return _xp_add(ctx, _actor_of(ctx), net_id, amount, note).text


func _net_xp_add(ctx: CommandRegistry.Context) -> int:
	var amount: int = _debug_command(NetProtocol.DEBUG_XP_ADD, ctx.payload).get_xp_amount()
	if amount < 1 or amount > MAX_XP_ADD:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var net_id: int = _net_target(ctx)
	if net_id == 0:
		return CommandRegistry.Result.REFUSED
	return _network_result(ctx, net_id, _xp_add(ctx, _actor_of(ctx), net_id, amount, NOTE_DEBUG))


# XP as one more source (GM source: levels up with its LEVEL_UP), in a GM operation with no entries or events.
func _xp_add(ctx: CommandRegistry.Context, actor: Actor, net_id: int, amount: int, note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	var args: Array = [_character_arg(player), str(amount)]
	ctx.audit_args = {"args": args}
	var curve: LevelCurve = LevelCurve.shared()
	if player.record.xp_total >= curve.total_to(curve.level_cap):
		return _fail(TEXT_LEVEL_CAP % name)
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	var op: EconomyOp = _begin(player, actor, EconomyOp.Kind.GM, note, "xp_add", args)
	if op == null:
		return _fail(TEXT_NO_IDS)
	var old_level: int = player.record.level
	var old_xp: int = player.record.xp_total
	player.add_xp(amount, ProgressMessages.XpSource.GM)
	_xp_detail(op, old_level, old_xp, player)
	svc.after_level_change(net_id, old_level, _tick())
	_commit(ctx, net_id, op)
	return _done("%s gana %d de XP: nivel %d, %d de XP (operación %d)." % [name, player.record.xp_total - old_xp,
			player.record.level, player.record.xp_total, op.op_id])


# --- mastery_set and inv_show --------------------------------------------------------------------------

func _console_mastery_set(_ctx: CommandRegistry.Context) -> String:
	return TEXT_MASTERY


func _console_inv_show(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return _usage(ctx, _commands.get_usage(&"inv_show"))
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	_stats[&"queries"] += 1
	var player: PlayerProgress = _svc().get_player(net_id)
	ctx.audit_args = {"args": [_character_arg(player)]}
	var record: ProgressRecord = player.record
	var lines := PackedStringArray()
	lines.append("Inventario de %s (%s): nivel %d, %d de XP, %d puntos de reino; %s; bolsa de %d." % [
			_name_of(net_id), _who(player), record.level, record.xp_total, record.realm_points, _wallets_text(record),
			record.bag_slots])
	var active: int = _svc().active_weapon_slot(net_id)
	for container: int in InventoryState.OPEN_CONTAINERS:
		var label: String = "Equipo" if container == InventoryState.ContainerId.EQUIPMENT else "Bolsa"
		var parts := PackedStringArray()
		for slot: int in range(record.inventory.slot_count(container)):
			var item: ItemInstance = record.inventory.get_item(container, slot)
			if item == null:
				continue
			var text: String = "%d %s ×%d uid %d%s" % [slot, item.def_id, item.count, item.uid,
					" ligado" if item.bound else ""]
			if container == InventoryState.ContainerId.EQUIPMENT and slot == active:
				text += " (activa)"
			parts.append(text)
		if parts.is_empty():
			lines.append("%s: vacío." % label)
		for start: int in range(0, parts.size(), ITEMS_PER_LINE):
			lines.append("%s: %s." % [label, " · ".join(parts.slice(start, start + ITEMS_PER_LINE))])
	return _respond(ctx, lines)


# --- ledger_show -------------------------------------------------------------------------------------

func _console_ledger_show(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return _usage(ctx, _commands.get_usage(&"ledger_show"))
	var limit: int = DEFAULT_LEDGER_ENTRIES
	if ctx.args.size() == 2:
		if not ctx.args[1].is_valid_int() or ctx.args[1].to_int() < 1 or ctx.args[1].to_int() > MAX_LEDGER_ENTRIES:
			return _usage(ctx, _commands.get_usage(&"ledger_show"))
		limit = ctx.args[1].to_int()
	var net_id: int = _target(ctx, ctx.args[0])
	if net_id == 0:
		return TEXT_NOBODY % ctx.args[0]
	_stats[&"queries"] += 1
	var player: PlayerProgress = _svc().get_player(net_id)
	ctx.audit_args = {"args": [_character_arg(player), str(limit)]}
	if _platform == null or not player.persistent:
		return _respond(ctx, _ledger_lines(net_id, player, limit, []))
	if _platform.is_fenced():
		return TEXT_PLATFORM_DOWN
	_stats[&"route_requests"] += 1
	_platform.request(PlatformEvent.KIND_PROGRESS_LEDGER, HTTPClient.METHOD_GET,
			"/internal/v1/characters/%d/ledger?limit=%d" % [player.character_id, limit], {},
			PlatformClient.PRIORITY_PLAYER, {"purpose": "ledger_show", "actor": _actor_of(ctx), "net_id": net_id,
			"character_id": player.character_id, "limit": limit})
	return _pending_text(ctx, "libro de %s" % _name_of(net_id))


func _on_ledger_show(event: PlatformEvent, actor: Actor, net_id: int, character_id: int, limit: int) -> void:
	var player: PlayerProgress = _svc().get_player(net_id)
	if player == null or player.character_id != character_id:
		_reply(actor, PackedStringArray(["El personaje %d ya no está en esta zona." % character_id]))
		return
	if not event.is_success():
		_reply(actor, PackedStringArray([_route_failure(event)]))
		return
	var saved: Array = []
	for value: Variant in PlatformJson.array_in(event.body_dict(), "entries"):
		var entry: Dictionary = value if value is Dictionary else {}
		if not ProgressJson.is_id(entry.get("op_id")) or not ProgressJson.is_int(entry.get("currency"), 1, 0xFF) \
				or not ProgressJson.is_int(entry.get("delta"), -Currency.CAP, Currency.CAP) \
				or not ProgressJson.is_int(entry.get("balance_after"), 0, Currency.CAP) \
				or not ProgressJson.is_int(entry.get("reason"), 1, 0xFF):
			_reply(actor, PackedStringArray([TEXT_BAD_ANSWER]))
			return
		saved.append({"op_id": ProgressJson.id_value(entry["op_id"]), "currency": int(entry["currency"]),
				"delta": int(entry["delta"]), "balance_after": int(entry["balance_after"]),
				"reason": int(entry["reason"])})
	_reply(actor, _ledger_lines(net_id, player, limit, saved))


# The latest limit entries: first those from the unconfirmed journal (the most recent) and then the saved ones.
func _ledger_lines(net_id: int, player: PlayerProgress, limit: int, saved: Array) -> PackedStringArray:
	var lines := PackedStringArray()
	var journal: Array[EconomyOp] = player.journal()
	var shown: int = 0
	for i: int in range(journal.size() - 1, -1, -1):
		var op: EconomyOp = journal[i]
		for j: int in range(op.ledger.size() - 1, -1, -1):
			if shown >= limit:
				break
			var entry: LedgerEntry = op.ledger[j]
			lines.append(_entry_text(op.op_id, entry.currency, entry.delta, entry.balance_after, entry.reason)
					+ (" · sin guardar" if player.persistent else ""))
			shown += 1
	for value: Variant in saved:
		if shown >= limit:
			break
		var entry: Dictionary = value
		lines.append(_entry_text(entry["op_id"], entry["currency"], entry["delta"], entry["balance_after"],
				entry["reason"]))
		shown += 1
	var pending: int = player.pending_aggregate_count()
	var head := PackedStringArray(["Libro de %s (%s), %d apuntes%s:" % [_name_of(net_id), _who(player), shown,
			" y %d agregados aún sin cerrar" % pending if pending > 0 else ""]])
	head.append_array(lines)
	return head


# --- op_show -----------------------------------------------------------------------------------------

func _console_op_show(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1 or not ProgressJson.is_id(ctx.args[0]):
		return _usage(ctx, _commands.get_usage(&"op_show"))
	var op_id: int = ProgressJson.id_value(ctx.args[0])
	ctx.audit_args = {"op_id": ctx.args[0]}
	_stats[&"queries"] += 1
	var found: Array = _find_in_journals(op_id)
	if not found.is_empty():
		var player: PlayerProgress = found[1]
		ctx.target = _entity(found[0])
		return _respond(ctx, _op_lines(OpView.from_journal(found[2], player.character_id), player.persistent))
	if _platform == null:
		return TEXT_NO_OP % op_id
	if _platform.is_fenced():
		return TEXT_PLATFORM_DOWN
	_stats[&"route_requests"] += 1
	_platform.request(PlatformEvent.KIND_PROGRESS_OP, HTTPClient.METHOD_GET, "/internal/v1/ops/%d" % op_id, {},
			PlatformClient.PRIORITY_PLAYER, {"purpose": "op_show", "actor": _actor_of(ctx), "op_id": op_id})
	return _pending_text(ctx, "operación %d" % op_id)


func _on_op_show(event: PlatformEvent, actor: Actor, op_id: int) -> void:
	if not event.is_success():
		_reply(actor, PackedStringArray([TEXT_NO_OP % op_id if event.status == 404 else _route_failure(event)]))
		return
	var view: OpView = OpView.from_route(event.body_dict())
	if view == null:
		_reply(actor, PackedStringArray([TEXT_BAD_ANSWER]))
		return
	_reply(actor, _op_lines(view, true))


func _op_lines(view: OpView, persistent: bool) -> PackedStringArray:
	var lines := PackedStringArray()
	var participants := PackedStringArray()
	for character_id: int in view.participants:
		participants.append(str(character_id))
	var head: String = "Operación %d (%s) de %s" % [view.op_id, EconomyOp.kind_name(view.kind),
			"personaje " + ", ".join(participants) if persistent else "un efímero"]
	if view.actor_account_id != 0:
		head += ", actor %d" % view.actor_account_id
	if not view.note.is_empty():
		head += ", nota «%s»" % view.note
	if view.detail.has("command"):
		head += ", comando %s" % String(view.detail["command"])
	if view.ref_op_id != 0:
		head += ", revierte la %d" % view.ref_op_id
	if view.reversed_by != 0:
		head += ", revertida por la %d" % view.reversed_by
	if not view.saved and persistent:
		head += ", sin guardar"
	lines.append(head + ".")
	for entry: Dictionary in view.ledger:
		lines.append("Apunte: " + _entry_text(view.op_id, entry["currency"], entry["delta"], entry["balance_after"],
				entry["reason"]).trim_prefix("op %d · " % view.op_id))
	for event: Dictionary in view.items:
		var uid: int = event["uid"]
		lines.append("Evento: %s %+d%s (%s)" % [event["def_id"], event["count_delta"],
				" uid %d" % uid if uid != 0 else "", _reason_name(event["reason"])])
	if view.detail.has("xp_delta"):
		lines.append("XP: %+d (nivel %s → %s)" % [int(view.detail["xp_delta"]), str(view.detail.get("level_before")),
				str(view.detail.get("level_after"))])
	return lines


# --- op_revert ----------------------------------------------------------------------------------------

func _console_op_revert(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() < 2 or not ProgressJson.is_id(ctx.args[0]):
		return _usage(ctx, _commands.get_usage(&"op_revert"))
	var op_id: int = ProgressJson.id_value(ctx.args[0])
	var note: String = _note(ctx, 1)
	if note.is_empty():
		return _usage(ctx, _commands.get_usage(&"op_revert"))
	ctx.audit_args = {"args": [str(op_id)]}
	var actor: Actor = _actor_of(ctx)
	# A REVERSAL of its own in a journal: without a platform, already reverted; with one, not yet confirmed.
	for net_id: int in _svc().player_net_ids():
		for op: EconomyOp in _svc().get_player(net_id).journal():
			if op.kind == EconomyOp.Kind.REVERSAL and op.ref_op_id == op_id:
				return _refused_text(TEXT_REVERTING if _platform != null else TEXT_REVERTED)
	if _pending_reverts.has(op_id):
		return _refused_text(TEXT_REVERTING)
	var found: Array = _find_in_journals(op_id)
	if _platform == null:
		if found.is_empty() or not _svc().is_connected_player(found[0]):
			return _refused_text(TEXT_NO_OP % op_id)
		var player: PlayerProgress = found[1]
		ctx.target = _entity(found[0])
		return _revert(ctx, actor, found[0], OpView.from_journal(found[2], player.character_id), note).text
	if not found.is_empty():
		return _refused_text(TEXT_NOT_SAVED)
	if _platform.is_fenced():
		_stats[&"fenced"] += 1
		return _refused_text(TEXT_PLATFORM_DOWN)
	# The REVERSAL is created with the response; its audit entry, with its op:<op_id>, too.
	ctx.audit_deferred = true
	_pending_reverts[op_id] = true
	_stats[&"route_requests"] += 1
	_platform.request(PlatformEvent.KIND_PROGRESS_OP, HTTPClient.METHOD_GET, "/internal/v1/ops/%d" % op_id, {},
			PlatformClient.PRIORITY_PLAYER, {"purpose": "op_revert", "actor": actor, "op_id": op_id, "note": note})
	return _pending_text(ctx, "operación %d para revertirla" % op_id)


func _on_op_revert(event: PlatformEvent, actor: Actor, op_id: int, note: String) -> void:
	_pending_reverts.erase(op_id)
	var ctx: CommandRegistry.Context = _deferred_context(actor, op_id)
	var reply: _Reply = _revert_answer(event, ctx, actor, op_id, note)
	if not reply.ok:
		_stats[&"refused"] += 1
	_reply(actor, PackedStringArray([reply.text]))
	if _commands != null and _commands.audit_entry_sink.is_valid():
		_commands.audit_entry_sink.call(ctx, &"op_revert", "ok" if reply.ok else reply.text)


func _revert_answer(event: PlatformEvent, ctx: CommandRegistry.Context, actor: Actor, op_id: int,
		note: String) -> _Reply:
	if not event.is_success():
		return _fail(TEXT_NO_OP % op_id if event.status == 404 else _route_failure(event))
	var view: OpView = OpView.from_route(event.body_dict())
	if view == null or view.op_id != op_id:
		return _fail(TEXT_BAD_ANSWER)
	if view.reversed_by != 0:
		return _fail(TEXT_REVERTED)
	var net_id: int = 0
	for character_id: int in view.participants:
		net_id = _svc().connected_net_id_of(character_id)
		if net_id != 0:
			break
	if net_id == 0:
		return _fail(TEXT_NOT_HERE % op_id)
	# Another reversal that arrived earlier and is not yet saved.
	for op: EconomyOp in _svc().get_player(net_id).journal():
		if op.kind == EconomyOp.Kind.REVERSAL and op.ref_op_id == op_id:
			return _fail(TEXT_REVERTING)
	ctx.target = _entity(net_id)
	return _revert(ctx, actor, net_id, view, note)


# The REVERSAL of view on net_id (§10), all or nothing.
func _revert(ctx: CommandRegistry.Context, actor: Actor, net_id: int, view: OpView, note: String) -> _Reply:
	var svc: ProgressService = _svc()
	var player: PlayerProgress = svc.get_player(net_id)
	var name: String = _name_of(net_id)
	var args: Array = [str(view.op_id)]
	ctx.audit_args = {"args": args}
	if view.kind == EconomyOp.Kind.REVERSAL or view.kind == EconomyOp.Kind.MIGRATION:
		return _fail(TEXT_CANNOT_REVERT % EconomyOp.kind_name(view.kind).to_upper())
	var refusal: String = _refusal(actor, player)
	if not refusal.is_empty():
		return _fail(refusal)
	var character_id: int = view.participants[0] if not view.participants.is_empty() else player.character_id
	var ledger: Array[Dictionary] = []
	var items: Array[Dictionary] = []
	for entry: Dictionary in view.ledger:
		if entry["character_id"] == character_id:
			ledger.append(entry)
	for event: Dictionary in view.items:
		if event["character_id"] == character_id:
			items.append(event)
	var raw_delta: Variant = view.detail.get("xp_delta")
	var xp_delta: int = int(raw_delta) if raw_delta is int or raw_delta is float else 0
	if ledger.is_empty() and items.is_empty() and xp_delta == 0:
		return _fail(TEXT_NOTHING_TO_REVERT % view.op_id)
	# What is missing, before touching anything: a balance that would go negative or what they no longer have.
	var state: InventoryState = player.record.inventory
	var protected: Array[Vector2i] = [Vector2i(InventoryState.ContainerId.EQUIPMENT, svc.active_weapon_slot(net_id))]
	var totals: Dictionary[int, int] = {}
	for entry: Dictionary in ledger:
		totals[entry["currency"]] = totals.get(entry["currency"], 0) - int(entry["delta"])
	for currency: int in totals:
		var after: int = player.record.wallets[currency] + totals[currency]
		if after < 0:
			return _fail(TEXT_SHORT_CURRENCY % [name, -after, _currency_name(currency)])
		if after > Currency.CAP:
			return _fail(TEXT_BALANCE % [name, player.record.wallets[currency], _currency_name(currency),
					totals[currency]])
	var needed: Dictionary[StringName, int] = {}
	for event: Dictionary in items:
		if event["count_delta"] > 0:
			needed[event["def_id"]] = needed.get(event["def_id"], 0) + int(event["count_delta"])
	for def_id: StringName in needed:
		var have: int = InventoryOps.count_outside(state, def_id, protected)
		if have < needed[def_id]:
			return _fail(TEXT_SHORT_ITEMS % [name, needed[def_id] - have, def_id])
	var detail: Dictionary = _detail(actor, "op_revert", args)
	var op: EconomyOp = player.begin_op(EconomyOp.Kind.REVERSAL, actor.account_id, note, detail)
	if op == null:
		return _fail(TEXT_NO_IDS)
	op.ref_op_id = view.op_id
	var realm_delta: int = 0
	var gives_realm: bool = false
	for entry: Dictionary in ledger:
		var delta: int = -int(entry["delta"])
		if not player.change_currency(op, entry["currency"], delta, EconomyReason.REVERSAL, LedgerEntry.RefKind.OP,
				view.op_id):
			player.abort_op(op)
			return _fail(TEXT_BALANCE % [name, player.record.wallets[entry["currency"]],
					_currency_name(entry["currency"]), delta])
		if entry["currency"] == Currency.Code.MERITS:
			realm_delta += delta
			gives_realm = gives_realm or EconomyReason.gives_realm_points(entry["reason"])
	# I9: merits with reason 3–5 raised realm points; reverting them lowers them by the same amount (S6).
	if gives_realm:
		player.record.realm_points = maxi(player.record.realm_points + realm_delta, 0)
	var changed: Array[Vector2i] = []
	var weapons_changed: bool = false
	for event: Dictionary in items:
		var count: int = int(event["count_delta"])
		var outcome: InventoryOps.Outcome
		if count > 0:
			outcome = player.op_remove_items(op, event["def_id"], count, EconomyReason.REVERSAL, event["uid"], protected)
		else:
			outcome = player.op_create_items(op, event["def_id"], -count, EconomyReason.REVERSAL,
					_template_for(view, event))
		if not outcome.is_ok():
			player.abort_op(op)
			match outcome.result:
				InventoryOps.Result.NO_ROOM:
					return _fail(TEXT_BAG_FULL % name + " No se revierte nada.")
				InventoryOps.Result.STALE:
					return _fail(TEXT_SHORT_ITEMS % [name, count, event["def_id"]])
				InventoryOps.Result.INVALID:
					return _fail(TEXT_NO_ITEM % event["def_id"])
			return _fail(TEXT_NO_IDS)
		changed.append_array(outcome.changed)
		weapons_changed = weapons_changed or outcome.weapons_changed
	if weapons_changed and not svc.can_change_weapons(net_id):
		player.abort_op(op)
		return _fail(TEXT_BUSY % name)
	var old_level: int = player.record.level
	var old_xp: int = player.record.xp_total
	if xp_delta != 0:
		var curve: LevelCurve = LevelCurve.shared()
		player.record.xp_total = clampi(old_xp - xp_delta, 0, curve.total_to(curve.level_cap))
		player.record.level = curve.level_for(player.record.xp_total)
		_xp_detail(op, old_level, old_xp, player)
	var s: int = _tick()
	if not changed.is_empty() or weapons_changed:
		var reason: int = EconomyReason.REVERSAL
		svc.after_gm_change(net_id, changed, weapons_changed, reason, s)
	svc.after_level_change(net_id, old_level, s)
	_commit(ctx, net_id, op)
	_stats[&"reversals"] += 1
	return _done("Operación %d de %s revertida (operación %d)." % [view.op_id, name, op.op_id])


# What is recreated from an event that removed (§10): the fields of the withdrawn row of its uid if there is one;
# otherwise, bound.
func _template_for(view: OpView, event: Dictionary) -> ItemInstance:
	var uid: int = event["uid"]
	var row: ItemInstance = view.instances.get(uid) if uid != 0 else null
	if row != null and row.def_id == event["def_id"]:
		return row
	var definition: ItemDefinition = _db.get_definition(event["def_id"])
	if definition == null:
		return null
	var template: ItemInstance = ItemInstance.create(0, definition, 1)
	template.bound = true
	return template


# --- Common code ---------------------------------------------------------------------------------

func _svc() -> ProgressService:
	return _service.get_ref() as ProgressService


func _tick() -> int:
	return _zone.get_tick() + 1 if _zone != null else 0


func _entity(net_id: int) -> NetEntity:
	return _zone.get_registry().get_entity(net_id) if _zone != null and _zone.get_registry() != null else null


func _name_of(net_id: int) -> String:
	var peer: ServerPeer = _svc().peer_of(net_id)
	if peer != null:
		return peer.display_name
	var entity: NetEntity = _entity(net_id)
	return entity.display_name if entity != null else "net_id %d" % net_id


static func _who(player: PlayerProgress) -> String:
	return "personaje %d" % player.character_id if player.persistent else "efímero"


# The target of a console or /gm command (a player with progress connected here), noted in ctx.target for the audit;
# 0 if there is none.
func _target(ctx: CommandRegistry.Context, text: String) -> int:
	var net_id: int = _svc().find_connected(text)
	if net_id != 0:
		ctx.target = _entity(net_id)
	return net_id


# That of a DEBUG_COMMAND: whoever sends it, if they have progress.
func _net_target(ctx: CommandRegistry.Context) -> int:
	if ctx.peer == null or ctx.peer.entity == null:
		return 0
	var net_id: int = ctx.peer.entity.net_id
	if not _svc().is_connected_player(net_id):
		return 0
	ctx.target = ctx.peer.entity
	return net_id


func _actor_of(ctx: CommandRegistry.Context) -> Actor:
	var actor := Actor.new()
	actor.origin = ctx.origin
	actor.role = ctx.role
	match ctx.origin:
		CommandRegistry.Origin.CHAT:
			actor.source = SOURCE_GM
		CommandRegistry.Origin.NETWORK:
			actor.source = SOURCE_DEBUG
		_:
			actor.source = SOURCE_CONSOLE
	if ctx.origin != CommandRegistry.Origin.CONSOLE:
		actor.peer = ctx.peer
		if ctx.peer != null and ctx.peer.claimed != null:
			actor.account_id = ctx.peer.claimed.account_id
			actor.character_id = ctx.peer.claimed.character_id
	return actor


# The rule of one's own characters and the fenced zone (§10): the text if it cannot be done, or empty.
func _refusal(actor: Actor, player: PlayerProgress) -> String:
	if actor.account_id != 0 and player.persistent and player.account_id == actor.account_id \
			and actor.role != CommandRegistry.ROLE_ADMIN:
		_stats[&"forbidden_own"] += 1
		return TEXT_OWN_CHARACTERS
	if _platform != null and _platform.is_fenced():
		_stats[&"fenced"] += 1
		return TEXT_PLATFORM_DOWN
	return ""


# The trail detail of §10.
func _detail(actor: Actor, command: String, args: Array) -> Dictionary:
	return {
		"command": command, "args": args.duplicate(), "source": actor.source,
		"actor_character_id": ProgressJson.id_text(actor.character_id) if actor.character_id != 0 else null,
		"at_unix": _svc().now_unix(),
	}


func _begin(player: PlayerProgress, actor: Actor, kind: int, note: String, command: String,
		args: Array) -> EconomyOp:
	return player.begin_op(kind, actor.account_id, note.left(EconomyOp.MAX_NOTE_LENGTH), _detail(actor, command, args))


# Level and XP from before and after in the detail of an operation that touches them (§10).
static func _xp_detail(op: EconomyOp, old_level: int, old_xp: int, player: PlayerProgress) -> void:
	op.detail["level_before"] = old_level
	op.detail["level_after"] = player.record.level
	op.detail["xp_before"] = old_xp
	op.detail["xp_after"] = player.record.xp_total
	op.detail["xp_delta"] = player.record.xp_total - old_xp


# The operation is already done: critical save and the audit with its op:<op_id>, the args of its row (those of detail
# that do not go in its column) and its time.
func _commit(ctx: CommandRegistry.Context, net_id: int, op: EconomyOp) -> void:
	_svc().mark_gm_critical(net_id)
	_stats[&"ops"] += 1
	ctx.audit_key = "op:%d" % op.op_id
	ctx.audit_at_unix = int(op.detail.get("at_unix", 0))
	var args: Dictionary = {}
	for key: String in op.detail:
		if not DETAIL_COLUMNS.has(key):
			args[key] = op.detail[key]
	ctx.audit_args = args
	ctx.note = "operación %d" % op.op_id
	_svc().log_line("Progreso: %s crea la operación %d (%s, %s) sobre net_id %d" % [_actor_text(ctx), op.op_id,
			EconomyOp.kind_name(op.kind), op.detail.get("command", ""), net_id])


func _actor_text(ctx: CommandRegistry.Context) -> String:
	return ctx.source if not ctx.source.is_empty() else "consola"


# The network result of a command that changes something: OK, or REFUSED with the reason in the audit and in a NOTICE.
func _network_result(ctx: CommandRegistry.Context, net_id: int, reply: _Reply) -> int:
	if reply.ok:
		return CommandRegistry.Result.OK
	ctx.note = reply.text
	_svc().notice(net_id, reply.text)
	return CommandRegistry.Result.REFUSED


# The audit entry assembled by the response of an op_revert with a platform: the command's, with its target and, if
# it created the REVERSAL, its op:<op_id> (set by _commit).
func _deferred_context(actor: Actor, op_id: int) -> CommandRegistry.Context:
	var ctx := CommandRegistry.Context.new()
	ctx.origin = actor.origin if actor != null else CommandRegistry.Origin.CONSOLE
	ctx.peer = actor.peer if actor != null else null
	ctx.role = actor.role if actor != null else &""
	ctx.source = "consola" if ctx.peer == null else "/gm peer %d (%s)" % [ctx.peer.peer_id, ctx.peer.display_name]
	ctx.args = PackedStringArray([str(op_id)])
	ctx.audit_args = {"args": [str(op_id)]}
	return ctx


# Looks for op_id in the journals of this zone: [net_id, PlayerProgress, EconomyOp], or empty.
func _find_in_journals(op_id: int) -> Array:
	for net_id: int in _svc().player_net_ids():
		var player: PlayerProgress = _svc().get_player(net_id)
		for op: EconomyOp in player.journal():
			if op.op_id == op_id:
				return [net_id, player, op]
	return []


func _note(ctx: CommandRegistry.Context, first: int) -> String:
	return " ".join(ctx.args.slice(first)).strip_edges() if ctx.args.size() > first else ""


static func _character_arg(player: PlayerProgress) -> String:
	return ProgressJson.id_text(player.character_id) if player.character_id > 0 else "0"


static func _currency_name(currency: int) -> String:
	return Currency.display_name(currency).to_lower()


static func _reason_name(reason: int) -> String:
	return EconomyReason.name_of(reason).to_lower()


static func _entry_text(op_id: int, currency: int, delta: int, balance_after: int, reason: int) -> String:
	return "op %d · %s %+d → %d (%s)" % [op_id, _currency_name(currency), delta, balance_after, _reason_name(reason)]


static func _wallets_text(record: ProgressRecord) -> String:
	var parts := PackedStringArray()
	for code: int in Currency.codes():
		parts.append("%s %d" % [_currency_name(code), record.wallets[code]])
	return ", ".join(parts)


func _route_failure(event: PlatformEvent) -> String:
	_svc().log_line("Progreso: consulta de GM rechazada (%s)" % ZonePlatform.describe(event))
	return TEXT_PLATFORM_DOWN


static func _usage(ctx: CommandRegistry.Context, usage: String) -> String:
	return "Uso: %s%s" % ["/gm " if ctx.origin == CommandRegistry.Origin.CHAT else "", usage]


func _refused_text(text: String) -> String:
	_stats[&"refused"] += 1
	return text


func _pending_text(ctx: CommandRegistry.Context, what: String) -> String:
	ctx.note = "pedida a la plataforma"
	return TEXT_REQUESTED % what


# The lines of a response: through the console, together; through /gm, one per system channel message (the last one is
# returned and sent by ModerationService).
func _respond(ctx: CommandRegistry.Context, lines: PackedStringArray) -> String:
	if lines.is_empty():
		return ""
	if ctx.origin != CommandRegistry.Origin.CHAT or ctx.peer == null:
		return "\n".join(lines)
	for i: int in range(lines.size() - 1):
		_svc().reply(ctx.peer, lines[i])
	return lines[lines.size() - 1]


# A response that arrives late (from a route): to the chat of whoever requested it if they are still in the world, or
# to the log.
func _reply(actor: Actor, lines: PackedStringArray) -> void:
	var peer: ServerPeer = actor.peer if actor != null else null
	if peer != null and actor.origin == CommandRegistry.Origin.CHAT:
		if peer.state == ServerPeer.State.IN_WORLD:
			for line: String in lines:
				_svc().reply(peer, line)
		return
	for line: String in lines:
		_svc().log_line(line)


func _debug_command(command_id: int, payload: PackedByteArray) -> NetMessages.DebugCommand:
	var command := NetMessages.DebugCommand.new()
	command.command = command_id
	command.payload = payload
	return command


func _fail(text: String) -> _Reply:
	_stats[&"refused"] += 1
	var reply := _Reply.new()
	reply.text = text
	return reply


static func _done(text: String) -> _Reply:
	var reply := _Reply.new()
	reply.ok = true
	reply.text = text
	return reply
