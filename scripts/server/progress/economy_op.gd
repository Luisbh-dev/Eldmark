class_name EconomyOp
extends RefCounted
## Una operación económica (docs/progresion.md §3.3, §5.2 y §9.3, PRG-12): lo que se aplica de una vez (I7) con
## sus apuntes ([LedgerEntry]) y sus eventos de objeto ([ItemEvent]). La zona guarda en el diario de
## [PlayerProgress] las que aún no ha confirmado un guardado; cada cuerpo lleva las que aún no iban en ninguno
## ([member save_seq] 0) y les pone su [code]seq[/code] (§9.2).
## [br][br]
## [b]JSON[/b] ([method to_dictionary], la entrada de [code]ops[/code] de §9.3): ids en cadena
## ([code]op_id[/code], [code]actor_account_id[/code] y [code]ref_op_id[/code], estos dos null si no hay), la
## [code]note[/code] null si está vacía y [code]detail[/code] tal cual. [member save_seq] no viaja. Solo
## servidor: sin reloj (la hora de [code]detail.at_unix[/code] la pone quien crea la operación, con
## [method ZonePlatform.now_unix]).

## Tipos de operación ([code]economy_ops.kind[/code], §5.3). Los mismos números que
## [constant ProgressionRulesExport.OP_KINDS] (lo comprueba [code]test_player_progress[/code]); 7 TRADE y 8 MAIL
## son de la fase 6 y del 9 al 15, reservados.
enum Kind { PLAYER = 1, GAMEPLAY = 2, STARTER_KIT = 3, GM = 4, REVERSAL = 5, MIGRATION = 6 }

## Claves de [method to_dictionary], en orden alfabético.
const DICTIONARY_KEYS: Array[String] = ["actor_account_id", "detail", "items", "kind", "ledger", "note",
		"op_id", "ref_op_id"]
## Longitud máxima de [member note] (la columna, §3.3).
const MAX_NOTE_LENGTH: int = 200
## Tipos que [method from_dictionary] admite (1–15, §3.3).
const MAX_KIND: int = 15
## Motivos que admite cada tipo en apuntes y eventos (S2 de §13.3).
const KIND_REASONS: Dictionary[int, Array] = {
	Kind.PLAYER: [EconomyReason.PLAYER_DESTROY],
	Kind.GAMEPLAY: [EconomyReason.CAMP_REFILL, EconomyReason.PVP_KILL, EconomyReason.PVP_ASSIST,
			EconomyReason.OBJECTIVE, EconomyReason.NPC_KILL, EconomyReason.CONSUME],
	Kind.STARTER_KIT: [EconomyReason.STARTER_KIT],
	Kind.GM: [EconomyReason.GM_GRANT, EconomyReason.GM_REMOVE],
	Kind.REVERSAL: [EconomyReason.REVERSAL],
	Kind.MIGRATION: [EconomyReason.MIGRATION],
}

## 1 … 2^53 − 1; del mismo bloque de ids que los [code]uid[/code] (§4.5).
var op_id: int = 0
## [enum Kind].
var kind: int = 0
## La cuenta del GM en GM y REVERSAL; 0 (null) en las demás y desde la consola.
var actor_account_id: int = 0
## La operación revertida (REVERSAL); 0 (null) en las demás.
var ref_op_id: int = 0
## El motivo escrito (GM, REVERSAL; «debug» por DEBUG_COMMAND); vacío (null) en las demás.
var note: String = ""
## El rastro de §10 ([code]command[/code], [code]args[/code], [code]source[/code], [code]actor_character_id[/code],
## [code]at_unix[/code]…); vacío en las de juego.
var detail: Dictionary = {}
var ledger: Array[LedgerEntry] = []
var items: Array[ItemEvent] = []
## El [code]seq[/code] del cuerpo en el que salió; 0 = aún en ningún guardado (§9.2).
var save_seq: int = 0


## Una operación de [param op_kind] con [param id], sin apuntes ni eventos.
static func create(id: int, op_kind: int, actor: int = 0, op_note: String = "",
		op_detail: Dictionary = {}) -> EconomyOp:
	var op := EconomyOp.new()
	op.op_id = id
	op.kind = op_kind
	op.actor_account_id = actor
	op.note = op_note
	op.detail = op_detail.duplicate(true)
	return op


## true si no lleva apuntes ni eventos.
func is_empty() -> bool:
	return ledger.is_empty() and items.is_empty()


## true si cada apunte y cada evento usa un motivo de su tipo ([constant KIND_REASONS]) y, en GM y REVERSAL, la
## [member note] no está vacía: lo que exige S2 (§13.3) de la forma de la operación.
func is_consistent() -> bool:
	var allowed: Array = KIND_REASONS.get(kind, [])
	if allowed.is_empty():
		return false
	for entry: LedgerEntry in ledger:
		if not allowed.has(entry.reason):
			return false
	for event: ItemEvent in items:
		if not allowed.has(event.reason):
			return false
	if (kind == Kind.GM or kind == Kind.REVERSAL) and note.strip_edges().is_empty():
		return false
	return true


## La entrada de [code]ops[/code] de un guardado (§9.3).
func to_dictionary() -> Dictionary:
	var ledger_list: Array = []
	for entry: LedgerEntry in ledger:
		ledger_list.append(entry.to_dictionary())
	var item_list: Array = []
	for event: ItemEvent in items:
		item_list.append(event.to_dictionary())
	return {
		"op_id": ProgressJson.id_text(op_id),
		"kind": kind,
		"actor_account_id": null if actor_account_id == 0 else ProgressJson.id_text(actor_account_id),
		"ref_op_id": null if ref_op_id == 0 else ProgressJson.id_text(ref_op_id),
		"note": null if note.is_empty() else note,
		"detail": detail.duplicate(true),
		"ledger": ledger_list,
		"items": item_list,
	}


## Lee una entrada de [method to_dictionary] (la de un guardado, o la de la ruta de operación de P5d sin sus campos
## de más); null si no cuadra: una clave que falta o que no conoce, un id que no es una cadena decimal de 1 a
## 2^53 − 1 ([code]actor_account_id[/code] y [code]ref_op_id[/code], también null), un tipo fuera de 1–15, una
## [code]note[/code] que no es null ni texto de hasta 200 caracteres, un [code]detail[/code] que no es un objeto o
## un apunte o un evento que no se lee ([method LedgerEntry.from_dictionary], [method ItemEvent.from_dictionary]).
## No mira que los motivos cuadren con el tipo ([method is_consistent]): una operación antigua o de una migración
## se lee igual.
static func from_dictionary(data: Dictionary) -> EconomyOp:
	if data.size() != DICTIONARY_KEYS.size():
		return null
	for key: String in DICTIONARY_KEYS:
		if not data.has(key):
			return null
	if not ProgressJson.is_id(data["op_id"]) or not ProgressJson.is_int(data["kind"], 1, MAX_KIND):
		return null
	var op := EconomyOp.new()
	op.op_id = ProgressJson.id_value(data["op_id"])
	op.kind = int(data["kind"])
	for key: String in ["actor_account_id", "ref_op_id"]:
		if typeof(data[key]) == TYPE_NIL:
			continue
		if not ProgressJson.is_id(data[key]):
			return null
		op.set(key, ProgressJson.id_value(data[key]))
	var note_value: Variant = data["note"]
	if typeof(note_value) != TYPE_NIL:
		if typeof(note_value) != TYPE_STRING or String(note_value).length() > MAX_NOTE_LENGTH:
			return null
		op.note = note_value
	if typeof(data["detail"]) != TYPE_DICTIONARY:
		return null
	op.detail = (data["detail"] as Dictionary).duplicate(true)
	if typeof(data["ledger"]) != TYPE_ARRAY or typeof(data["items"]) != TYPE_ARRAY:
		return null
	for value: Variant in data["ledger"]:
		if typeof(value) != TYPE_DICTIONARY:
			return null
		var entry: LedgerEntry = LedgerEntry.from_dictionary(value)
		if entry == null:
			return null
		op.ledger.append(entry)
	for value: Variant in data["items"]:
		if typeof(value) != TYPE_DICTIONARY:
			return null
		var event: ItemEvent = ItemEvent.from_dictionary(value)
		if event == null:
			return null
		op.items.append(event)
	return op


## true si [param other] tiene los mismos valores (sin mirar [member save_seq]).
func equals(other: EconomyOp) -> bool:
	if other == null or op_id != other.op_id or kind != other.kind or actor_account_id != other.actor_account_id \
			or ref_op_id != other.ref_op_id or note != other.note or detail != other.detail \
			or ledger.size() != other.ledger.size() or items.size() != other.items.size():
		return false
	for i: int in range(ledger.size()):
		if not ledger[i].equals(other.ledger[i]):
			return false
	for i: int in range(items.size()):
		if not items[i].equals(other.items[i]):
			return false
	return true


## Nombre del tipo [param op_kind] en minúsculas (el de las reglas exportadas), o vacío.
static func kind_name(op_kind: int) -> String:
	for kind_key: String in Kind:
		if Kind[kind_key] == op_kind:
			return kind_key.to_lower()
	return ""


func _to_string() -> String:
	return "EconomyOp(%d, %s, %d apuntes, %d eventos, seq %d)" % [op_id, kind_name(kind), ledger.size(), items.size(),
			save_seq]
