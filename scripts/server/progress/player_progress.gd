class_name PlayerProgress
extends RefCounted
## El estado autoritativo del progreso de un personaje en la zona (docs/progresion.md §4, §5, §6 y §9): su
## [ProgressRecord] (inventario, monedas, nivel, temporizadores…), el diario de operaciones que aún no ha confirmado
## un guardado y lo agregado de las ganancias y gastos de juego. Lo crea [method ProgressService.prepare] (con
## plataforma) o el alta de un efímero (P5b) y lo descarta [method ProgressService.on_departure].
## [br][br]
## [b]Operaciones[/b] (§5.2): las sueltas ([method begin_op]: DESTROY del jugador, kit, GM, reversión) van al diario
## con sus apuntes y eventos, y antes de cada una se cierra lo agregado como una GAMEPLAY, así que el diario va
## siempre en orden de aplicación y cada [code]balance_after[/code] sale del saldo ya apuntado. Las de juego
## ([method gain_currency], [method gain_items], [method lose_items], [method camp_refill]) cambian el saldo o la
## bolsa al momento y se apuntan al construir el guardado: un apunte por (moneda, motivo, [code]ref_kind[/code],
## [code]ref_id[/code]) y un evento sin [code]uid[/code] por (definición, motivo).
## [br][br]
## [b]La sección [code]progress[/code][/b] (§9.2): [method build_section] cierra lo agregado con un id del tramo de
## los guardados (sin él devuelve [code]{}[/code] sin tocar nada), toma la foto y devuelve solo las operaciones con
## [member EconomyOp.save_seq] 0, a las que pone el [code]seq[/code]; [method acknowledge] quita del diario las de
## [code]save_seq ≤ seq[/code]; [method is_dirty] dice si hay algo que guardar en el punto de control.
## [br][br]
## [b]Ids[/b] ([IdAllocator], §4.5): las peticiones del cliente toman del tramo de los clientes, los cambios del
## servidor del suyo y el cierre de lo agregado al construir, del de los guardados. Solo servidor: sin reloj (la
## hora Unix llega en [member Live.now_unix], de [method ZonePlatform.now_unix]).

## Operaciones del diario sin confirmar a partir de las que un DESTROY da NOT_NOW (con plataforma, §4.2); sin ella,
## el diario guarda las últimas (§9.4).
const JOURNAL_LIMIT: int = 256
## Lo que hay que moverse para que la posición cuente como cambio en [method is_dirty] (m).
const MOVE_EPSILON_M: float = 0.1
## Ticks por segundo de los temporizadores (§8).
const TICKS_PER_SECOND: int = 60


## Lo que el cuerpo en el mundo aporta a la foto: lo da [member live_source] (lo pone
## [method ProgressService.on_arrival]; las pruebas, a mano).
class Live:
	extends RefCounted
	## [code]zone_id[/code], [code]channel[/code], [code]x[/code], [code]y[/code], [code]z[/code],
	## [code]yaw[/code] e [code]in_combat[/code] (§3.4); vacío = sin posición.
	var location: Dictionary = {}
	## Vida del [Combatant]; −1 = llena.
	var health: int = -1
	## Bit0 de [code]combat_flags2[/code] (la única fuente de la ranura activa, §4.1).
	var active_weapon_slot: int = 0
	## El cargado más lo jugado desde el alta.
	var played_seconds: int = 0
	## Hora Unix de la plataforma (0 = sin reloj: los temporizadores no se tocan).
	var now_unix: int = 0


## El registro vivo: lo que cambian las operaciones y lo que sale en cada foto.
var record: ProgressRecord
## true con plataforma (se guarda); false en un efímero (§9.4).
var persistent: bool = false
## 0 en un efímero.
var character_id: int = 0
var account_id: int = 0
## Tick del alta ([method ProgressService.on_arrival]); −1 antes.
var arrival_tick: int = -1
## El tiempo jugado cargado (el del registro en el alta): lo jugado se suma a este, no al de la última foto.
var played_base: int = 0
## [code]() -> Live[/code] (o null sin cuerpo): lo que aporta el cuerpo a la foto. Sin él, la foto usa lo del
## registro.
var live_source: Callable = Callable()
## Revisión del inventario de esta sesión (§4.6): empieza en 1 y sube con cada cambio aplicado. No se guarda.
var revision: int = 1
## XP ganada desde el último PROGRESS_UPDATE y su fuente ([enum ProgressMessages.XpSource]; P5c los manda y los
## pone a 0).
var pending_xp_gain: int = 0
var pending_xp_source: int = 0
## Motivo ([EconomyReason]) del último cambio de cada moneda (índice = moneda; 0 = ninguno): el de WALLET_UPDATE
## ([method ProgressService.flush]).
var last_currency_reasons: PackedInt32Array = PackedInt32Array()

var _ids: IdAllocator = null
var _db: ItemDatabase = null
var _journal: Array[EconomyOp] = []
## Saldo de cada moneda tras el último apunte del diario (lo que la plataforma verá apuntado).
var _ledger_balance: PackedInt64Array = PackedInt64Array()
## Lo agregado sin cerrar: clave → apunte (su balance_after se calcula al cerrar) y clave → evento sin uid.
var _pending_ledger: Dictionary[String, LedgerEntry] = {}
var _pending_items: Dictionary[String, ItemEvent] = {}
## Reutilizaciones de un arma que no está puesta (§4.1), por id de [CombatCatalog].
var _stashed: Dictionary[int, PackedInt64Array] = {}
## La foto del último guardado confirmado (o la del alta) y las de los cuerpos construidos sin confirmar, por seq.
var _confirmed: Dictionary = {}
var _built: Dictionary[int, Dictionary] = {}
## Lo de la última operación abierta con [method begin_op], para [method abort_op].
var _open_mark: Dictionary = {}
## Los uids vivos (uid → def_id) que tendrá la plataforma cuando le llegue el cuerpo siguiente: los del registro
## cargado y, tras cada [method build_section], los de su foto (los cuerpos de un personaje se aplican en orden).
var _saved_uids: Dictionary[int, StringName] = {}


func _init(p_record: ProgressRecord, p_persistent: bool, ids: IdAllocator, db: ItemDatabase) -> void:
	record = p_record if p_record != null else ProgressRecord.new_character()
	persistent = p_persistent
	_ids = ids if ids != null else IdAllocator.local()
	_db = db if db != null else ItemDatabase.shared()
	_ledger_balance = record.wallets.duplicate()
	last_currency_reasons.resize(Currency.WALLET_SIZE)
	_confirmed = _snapshot(null)
	_saved_uids = _live_uids()


## El generador de ids que usa.
func get_ids() -> IdAllocator:
	return _ids


## La foto del cuerpo de ahora es la confirmada: lo llama el alta (entrar sin cambiar nada no ensucia, §9.2).
func confirm_current() -> void:
	_confirmed = _snapshot(_live())


# --- Peticiones del cliente ----------------------------------------------------------------------

## Una petición del cliente ([InventoryOps.Request]) con [param context], del que el servidor ya ha puesto la
## ranura activa del [CombatState], [code]can_touch_equipment[/code] y [code]drinking[/code]; aquí se ponen el
## nivel, las definiciones y los ids del tramo de los clientes. Antes, el tope de DESTROY: con plataforma y
## [constant JOURNAL_LIMIT] operaciones o más sin confirmar, NOT_NOW (la plataforma no responde: el cuerpo no crece
## sin límite, §4.2). Un DESTROY aplicado crea su operación PLAYER con el evento PLAYER_DESTROY y el
## [member InventoryOps.Outcome.new_id] como [code]op_id[/code] (tras cerrar lo agregado).
func apply_request(request: InventoryOps.Request, context: InventoryOps.Context) -> InventoryOps.Outcome:
	if request.op == InventoryOps.Op.DESTROY and persistent and unconfirmed_count() >= JOURNAL_LIMIT:
		var refused := InventoryOps.Outcome.new()
		refused.result = InventoryOps.Result.NOT_NOW
		if record.inventory.has_slot(request.from_container, request.from_slot):
			refused.changed.append(Vector2i(request.from_container, request.from_slot))
		return refused
	context.db = _db
	context.level = record.level
	context.new_uid = _ids.next_for_client
	var outcome: InventoryOps.Outcome = InventoryOps.apply(record.inventory, request, context)
	if not outcome.is_ok():
		return outcome
	revision += 1
	if request.op == InventoryOps.Op.DESTROY:
		# El cierre de lo agregado va antes en el diario (§5.2); si no hubiera id del servidor (no pasa: quedaba uno
		# de los clientes), lo agregado se cierra después, y DESTROY no lleva apuntes que ordenar.
		_close_aggregate(_ids.next_for_server)
		var op: EconomyOp = EconomyOp.create(outcome.new_id, EconomyOp.Kind.PLAYER)
		op.items.assign(outcome.events)
		_append(op)
	return outcome


# --- Operaciones sueltas ---------------------------------------------------------------------------

## Abre una operación suelta de [param kind] (kit, GM, reversión) con el actor, la [param note] y el
## [param detail] del rastro (§10), tras cerrar lo agregado como una GAMEPLAY. Va al diario ya: lo que se le añada
## ([method add_items], [method remove_items], [method change_currency]) sale con ella. null si no hay ids del tramo
## del servidor (para cerrar o para ella; lo cerrado se queda en el diario). Guarda el estado de justo después de
## cerrar lo agregado para [method abort_op] (P5d: «todo o nada» de §10).
func begin_op(kind: int, actor_account_id: int, note: String, detail: Dictionary) -> EconomyOp:
	if not _close_aggregate(_ids.next_for_server):
		return null
	var id: int = _ids.next_for_server()
	if id == 0:
		return null
	var op: EconomyOp = EconomyOp.create(id, kind, actor_account_id, note, detail)
	_append(op)
	_open_mark = {
		"op": op, "inventory": record.inventory.duplicate_state(), "wallets": record.wallets.duplicate(),
		"ledger_balance": _ledger_balance.duplicate(), "realm_points": record.realm_points, "level": record.level,
		"xp_total": record.xp_total, "reasons": last_currency_reasons.duplicate(), "revision": revision,
		"pending_xp_gain": pending_xp_gain, "pending_xp_source": pending_xp_source,
	}
	return op


## Quita del diario [param op] si es la última, aún no ha salido en ningún cuerpo y no lleva nada (una operación que
## no se pudo completar: «todo o nada» de §10). Su id se pierde (un hueco no importa, §4.5). true si la quita.
func discard_op(op: EconomyOp) -> bool:
	if op == null or _journal.is_empty() or _journal[-1] != op or op.save_seq != 0 or not op.is_empty():
		return false
	_journal.pop_back()
	return true


## Deshace [param op] entera (P5d, «todo o nada» de §10): si es la última del diario, aún no ha salido en ningún
## cuerpo y es la última abierta con [method begin_op], vuelven el inventario, los saldos, los puntos de reino, el
## nivel y la XP de justo después de abrirla y la operación sale del diario (lo agregado que cerró se queda). Su id
## y los de las pilas que creó se pierden. true si la deshace.
func abort_op(op: EconomyOp) -> bool:
	if op == null or _open_mark.get("op") != op or _journal.is_empty() or _journal[-1] != op or op.save_seq != 0:
		return false
	record.inventory = _open_mark["inventory"]
	record.wallets = _open_mark["wallets"]
	_ledger_balance = _open_mark["ledger_balance"]
	record.realm_points = _open_mark["realm_points"]
	record.level = _open_mark["level"]
	record.xp_total = _open_mark["xp_total"]
	last_currency_reasons = _open_mark["reasons"]
	revision = _open_mark["revision"]
	pending_xp_gain = _open_mark["pending_xp_gain"]
	pending_xp_source = _open_mark["pending_xp_source"]
	_open_mark = {}
	_journal.pop_back()
	return true


## Crea [param count] unidades de [param def_id] en la bolsa dentro de [param op] (fuente o interno): a las pilas
## con hueco y el resto en pilas nuevas con ids del tramo del servidor. false si no cabe, faltan ids o la
## operación ya salió en un cuerpo: entonces nada cambia.
func add_items(op: EconomyOp, def_id: StringName, count: int, reason: int) -> bool:
	return op_add_items(op, def_id, count, reason).is_ok()


## [method add_items] con su [InventoryOps.Outcome] (las ranuras del INVENTORY_DELTA). Una operación cerrada da
## NOT_NOW.
func op_add_items(op: EconomyOp, def_id: StringName, count: int, reason: int) -> InventoryOps.Outcome:
	if not _is_open(op):
		return _refused(InventoryOps.Result.NOT_NOW)
	return _record_in(op, InventoryOps.add_items(record.inventory, def_id, count, reason, _server_context()))


## Crea [param count] unidades de [param def_id] dentro de [param op] en pilas nuevas en las primeras ranuras libres
## de la bolsa, sin juntar ([method InventoryOps.create_items]: el [code]item_give[/code] de GM y lo que recrea una
## reversión), copiando los campos de [param template] si la hay.
func op_create_items(op: EconomyOp, def_id: StringName, count: int, reason: int,
		template: ItemInstance = null) -> InventoryOps.Outcome:
	if not _is_open(op):
		return _refused(InventoryOps.Result.NOT_NOW)
	return _record_in(op, InventoryOps.create_items(record.inventory, def_id, count, reason, _server_context(),
			template))


## Quita [param count] unidades de [param def_id] dentro de [param op] (sumidero o interno), primero de
## [param prefer_uid]. false si no hay tantas o la operación ya salió en un cuerpo: entonces nada cambia. No mira la
## ranura activa (I10): quitar un arma equipada es cosa de quien llama.
func remove_items(op: EconomyOp, def_id: StringName, count: int, reason: int,
		prefer_uid: int = 0) -> bool:
	return op_remove_items(op, def_id, count, reason, prefer_uid).is_ok()


## [method remove_items] con su [InventoryOps.Outcome], sin tocar las ranuras de [param protected] (la activa del
## equipo en una reversión, §10).
func op_remove_items(op: EconomyOp, def_id: StringName, count: int, reason: int, prefer_uid: int = 0,
		protected: Array[Vector2i] = []) -> InventoryOps.Outcome:
	if not _is_open(op):
		return _refused(InventoryOps.Result.NOT_NOW)
	return _record_in(op, InventoryOps.remove_items(record.inventory, def_id, count, reason, prefer_uid, protected))


## Un apunte de [param delta] en [param currency] dentro de [param op], con su [code]balance_after[/code]. Entero o
## nada (§5.4): false si la moneda no existe, el signo no cuadra con el motivo, el saldo quedaría fuera de 0 … tope o
## la operación ya salió en un cuerpo. Los méritos de motivo 3–5 suben los puntos de reino (I9).
func change_currency(op: EconomyOp, currency: int, delta: int, reason: int, ref_kind: int,
		ref_id: int) -> bool:
	if not _is_open(op) or not Currency.is_valid(currency) or not EconomyReason.sign_matches(reason, delta):
		return false
	if not CurrencyRules.can_apply(record.wallets[currency], delta) \
			or not CurrencyRules.can_apply(_ledger_balance[currency], delta):
		return false
	record.wallets[currency] += delta
	_ledger_balance[currency] += delta
	last_currency_reasons[currency] = reason
	op.ledger.append(LedgerEntry.create(currency, delta, _ledger_balance[currency], reason, ref_kind, ref_id))
	if currency == Currency.Code.MERITS and EconomyReason.gives_realm_points(reason):
		record.realm_points = maxi(record.realm_points + delta, 0)
	return true


# --- Lo agregado -------------------------------------------------------------------------------------

## Una ganancia de juego (méritos, oro de PNJ y capturas): cambia el saldo al momento, recortada al tope (§5.4), y
## se apunta al construir el guardado. Los méritos de motivo 3–5 suben los puntos de reino. Devuelve lo aplicado
## (0 si la moneda no existe, el motivo no es una fuente o el saldo ya está en el tope).
func gain_currency(currency: int, amount: int, reason: int, ref_kind: int, ref_id: int) -> int:
	if not Currency.is_valid(currency) or not EconomyReason.is_source(reason):
		return 0
	var applied: int = CurrencyRules.clamp_gain(record.wallets[currency], amount)
	if applied <= 0:
		return 0
	record.wallets[currency] += applied
	last_currency_reasons[currency] = reason
	var key: String = "%d:%d:%d:%d" % [currency, reason, ref_kind, ref_id]
	if _pending_ledger.has(key):
		_pending_ledger[key].delta += applied
	else:
		_pending_ledger[key] = LedgerEntry.create(currency, applied, 0, reason, ref_kind, ref_id)
	if currency == Currency.Code.MERITS and EconomyReason.gives_realm_points(reason):
		record.realm_points += applied
	return applied


## Suma [param count] unidades de [param def_id] a la bolsa por el juego (agregado, con ids del tramo del servidor
## para las pilas nuevas). false si no cabe o faltan ids: nada cambia.
func gain_items(def_id: StringName, count: int, reason: int) -> bool:
	var outcome: InventoryOps.Outcome = InventoryOps.add_items(record.inventory, def_id, count, reason,
			_server_context())
	if not outcome.is_ok():
		return false
	_aggregate(outcome.events)
	revision += 1
	return true


## Quita [param count] unidades de [param def_id] por el juego (CONSUME: de la pila de la bolsa con la ranura más
## baja), agregado. false si no hay tantas: nada cambia.
func lose_items(def_id: StringName, count: int, reason: int) -> bool:
	return take_items(def_id, count, reason).is_ok()


## [method lose_items] con su [InventoryOps.Outcome]: las ranuras que cambiaron, para el INVENTORY_DELTA del
## servidor (P5b).
func take_items(def_id: StringName, count: int, reason: int) -> InventoryOps.Outcome:
	var outcome: InventoryOps.Outcome = InventoryOps.remove_items(record.inventory, def_id, count, reason)
	if outcome.is_ok():
		_aggregate(outcome.events)
		revision += 1
	return outcome


## CAMP_REFILL (§4.4) agregado: repone el total de cada definición con [member ItemDefinition.camp_refill]; una
## pila nueva toma un id del tramo del servidor y, sin él, esa parte espera al siguiente intento. Devuelve el
## resultado de [method InventoryOps.camp_refill] ([code]changed[/code] y [code]bag_full[/code], para el delta y el
## aviso de P5b).
func camp_refill() -> InventoryOps.Outcome:
	var outcome: InventoryOps.Outcome = InventoryOps.camp_refill(record.inventory, _server_context())
	if not outcome.events.is_empty():
		_aggregate(outcome.events)
		revision += 1
	return outcome


## Apuntes y eventos agregados sin cerrar (pruebas y métricas).
func pending_aggregate_count() -> int:
	return _pending_ledger.size() + _pending_items.size()


# --- Kit, XP y combate -------------------------------------------------------------------------------

## El kit de inicio (§2.5) de [param template_id] en una operación STARTER_KIT (ids del tramo del servidor), si
## [member ProgressRecord.starter_granted] es false; quien llama marca el guardado como crítico. false si ya se dio,
## si el inventario no está vacío o si faltan ids: entonces nada cambia ([code]starter_granted[/code] sigue false y
## llega en la siguiente entrada, §4.5). Una plantilla que no existe o que no se puede elegir usa la primera elegible
## por id, con aviso ([method StarterKit.template_for]).
func grant_starter_kit(template_id: StringName) -> bool:
	if record.starter_granted:
		return false
	if not record.inventory.all_items().is_empty():
		push_warning("[Eldmark] Progreso: el personaje %d no tiene el kit pero su inventario no está vacío"
				% character_id)
		return false
	var op: EconomyOp = begin_op(EconomyOp.Kind.STARTER_KIT, 0, "", {})
	if op == null:
		return false
	var events: Array[ItemEvent] = StarterKit.grant(record.inventory, template_id, _db, _ids.next_for_server)
	if events.is_empty():
		discard_op(op)
		return false
	op.items.assign(events)
	record.starter_granted = true
	revision += 1
	return true


## Suma [param amount] de XP ([method ProgressionRules.add_xp], I8) desde [param source]
## ([enum ProgressMessages.XpSource]); lo aplicado se acumula en [member pending_xp_gain] para PROGRESS_UPDATE.
func add_xp(amount: int, source: int) -> ProgressionRules.XpResult:
	var result: ProgressionRules.XpResult = ProgressionRules.add_xp(LevelCurve.shared(), record.level,
			record.xp_total, amount)
	record.level = result.level
	record.xp_total = result.xp_total
	if result.applied > 0:
		pending_xp_gain += result.applied
		pending_xp_source = source
	return result


## Las cargas de los consumibles (§4.4): [code]min(15, count_of(def))[/code] de cada uno de
## [method ItemDatabase.consumable_definition], empaquetadas como [member CombatState.consumable_charges].
func charges() -> int:
	var counts: Array[int] = [0, 0]
	for index: int in range(CombatState.CONSUMABLE_SLOTS):
		var definition: ItemDefinition = _db.consumable_definition(index)
		if definition != null:
			counts[index] = mini(record.inventory.count_of(definition.id), CombatState.MAX_CHARGES)
	return CombatState.pack_charges(counts[0], counts[1])


## La ranura activa con la que entra (§8): la del registro y, si no tiene arma y la otra sí, la otra (I10).
func saved_active_slot() -> int:
	return _effective_active_slot(record.active_weapon_slot)


## Las armas del equipo (ranuras 0 y 1) como ids de [CombatCatalog]; 0 = vacía.
func weapons() -> PackedInt32Array:
	var result := PackedInt32Array([0, 0])
	for slot: int in range(InventoryState.OPEN_EQUIPMENT_SLOTS):
		var item: ItemInstance = record.inventory.get_item(InventoryState.ContainerId.EQUIPMENT, slot)
		var definition: ItemDefinition = _db.get_definition(item.def_id) if item != null else null
		if definition != null and definition.category == ItemDefinition.Category.WEAPON:
			result[slot] = CombatCatalog.weapon_id(definition.ref_id)
	return result


## Guarda en memoria las reutilizaciones (ticks absolutos) del arma [param weapon_id] que se quita (§4.1).
func stash_ready(weapon_id: int, ready: PackedInt64Array) -> void:
	if weapon_id != 0:
		_stashed[weapon_id] = ready.duplicate()


## Las reutilizaciones guardadas del arma [param weapon_id] (vacío si no hay).
func stashed_ready(weapon_id: int) -> PackedInt64Array:
	return (_stashed.get(weapon_id, PackedInt64Array()) as PackedInt64Array).duplicate()


## El fin en hora Unix de una reutilización que acaba en el tick [param ready_tick], vista en el tick [param s] con
## la hora [param now_unix] (§8): [code]now_unix + ceili((ready_tick − s) / 60.0)[/code], entero y redondeado hacia
## arriba (nunca vence antes); una ya vencida da [param now_unix].
static func ends_at_unix_for(ready_tick: int, s: int, now_unix: int,
		ticks_per_second: int = TICKS_PER_SECOND) -> int:
	return now_unix + maxi(ceili(float(ready_tick - s) / float(ticks_per_second)), 0)


## El tick en que acaba, vista en el tick [param s] con la hora [param now_unix], una reutilización guardada con fin
## [param ends_at_unix] (§8): [code]s + max(0, ends_at_unix − now_unix) · 60[/code].
static func ready_tick_for(ends_at_unix: int, now_unix: int, s: int,
		ticks_per_second: int = TICKS_PER_SECOND) -> int:
	return s + maxi(ends_at_unix - now_unix, 0) * ticks_per_second


# --- La sección progress ------------------------------------------------------------------------------

## La sección [code]progress[/code] del guardado [param seq] (§9.3): cierra lo agregado como una GAMEPLAY con un id
## del tramo de los guardados, toma la foto (posición, giro, vida, «en combate», tiempo jugado y ranura activa del
## cuerpo; los temporizadores vencidos fuera) y devuelve el registro sin los campos de solo lectura con
## [code]ops[/code]: solo las operaciones con [member EconomyOp.save_seq] 0, a las que pone [param seq]. Sin id para
## cerrar lo agregado devuelve [code]{}[/code] sin tocar nada (§4.5).
## [br][br]
## [b]Uids de los eventos[/b] (S4, §13.3: un evento con [code]uid[/code] que suma es de uno que no estaba vivo en la
## base, y uno que resta, de uno que sí): el cuerpo lleva el [code]uid[/code] de un evento solo si cumple eso con lo
## que tendrá la base al recibirlo (la foto del cuerpo anterior o el registro cargado); si no, [code]null[/code],
## como un evento agregado. Pasa al destruir o quitar una pila que aún no se ha guardado (la mitad de un SPLIT) o al
## sumar a una que ya estaba guardada (el 16 de GM, que junta). Las cantidades no cambian, y el diario conserva el
## [code]uid[/code] de verdad.
func build_section(seq: int) -> Dictionary:
	if not _close_aggregate(_ids.next_for_build):
		return {}
	var live: Live = _live()
	_apply_live(live)
	var ops: Array = []
	for op: EconomyOp in _journal:
		if op.save_seq == 0:
			op.save_seq = seq
			ops.append(_saved_form(op))
	var data: Dictionary = record.to_dictionary()
	data["ops"] = ops
	_built[seq] = _snapshot(live)
	_saved_uids = _live_uids()
	return data


## Tras un 200 [code]applied[/code] o [code]duplicate[/code] del guardado [param seq]: quita del diario las
## operaciones con [code]save_seq ≤ seq[/code] y su foto pasa a ser la confirmada. Las de un cuerpo posterior en
## vuelo se quedan.
func acknowledge(seq: int) -> void:
	var kept: Array[EconomyOp] = []
	for op: EconomyOp in _journal:
		if op.save_seq == 0 or op.save_seq > seq:
			kept.append(op)
	_journal = kept
	if _built.has(seq):
		_confirmed = _built[seq]
	for built_seq: int in _built.keys():
		if built_seq <= seq:
			_built.erase(built_seq)


## true si hay algo que guardar en el punto de control (§9.2): una operación con [code]save_seq[/code] 0 o algo
## agregado, un campo del registro distinto del último confirmado (nivel, XP, puntos de reino, monedas, inventario,
## ranura activa, temporizadores…), la posición movida al menos [constant MOVE_EPSILON_M] o la vida distinta. El
## tiempo jugado solo no ensucia: va con el siguiente guardado.
func is_dirty() -> bool:
	if not _pending_ledger.is_empty() or not _pending_items.is_empty():
		return true
	for op: EconomyOp in _journal:
		if op.save_seq == 0:
			return true
	return _differs(_snapshot(_live()), _confirmed)


## El diario: con plataforma, las operaciones sin confirmar (en orden de aplicación); sin ella, las últimas
## [constant JOURNAL_LIMIT] (§9.4).
func journal() -> Array[EconomyOp]:
	return _journal.duplicate()


## Operaciones del diario sin confirmar (con plataforma, el tope de DESTROY).
func unconfirmed_count() -> int:
	return _journal.size()


# --- Interno -------------------------------------------------------------------------------------

func _server_context() -> InventoryOps.Context:
	var context := InventoryOps.Context.new()
	context.db = _db
	context.level = record.level
	context.new_uid = _ids.next_for_server
	return context


# Una operación del diario que aún no ha salido en ningún cuerpo (lo enviado no cambia).
func _is_open(op: EconomyOp) -> bool:
	return op != null and op.save_seq == 0 and _journal.has(op)


# Los uids vivos del inventario (uid → def_id).
func _live_uids() -> Dictionary[int, StringName]:
	var uids: Dictionary[int, StringName] = {}
	for item: ItemInstance in record.inventory.all_items():
		uids[item.uid] = item.def_id
	return uids


# La entrada de ops de [param op] en el cuerpo: sin el uid de los eventos que S4 no admitiría con lo guardado
# (ver build_section).
func _saved_form(op: EconomyOp) -> Dictionary:
	var data: Dictionary = op.to_dictionary()
	var events: Array = data["items"]
	for i: int in range(op.items.size()):
		var event: ItemEvent = op.items[i]
		if event.uid == 0:
			continue
		var saved: bool = _saved_uids.get(event.uid, &"") == event.def_id
		if (event.count_delta > 0 and _saved_uids.has(event.uid)) or (event.count_delta < 0 and not saved):
			(events[i] as Dictionary)["uid"] = null
	return data


static func _refused(result: int) -> InventoryOps.Outcome:
	var outcome := InventoryOps.Outcome.new()
	outcome.result = result
	return outcome


# Los eventos de [param outcome], si se aplicó, pasan a [param op] y la revisión sube.
func _record_in(op: EconomyOp, outcome: InventoryOps.Outcome) -> InventoryOps.Outcome:
	if outcome.is_ok():
		op.items.append_array(outcome.events)
		revision += 1
	return outcome


func _append(op: EconomyOp) -> void:
	_journal.append(op)
	if not persistent:
		while _journal.size() > JOURNAL_LIMIT:
			_journal.pop_front()


func _aggregate(events: Array[ItemEvent]) -> void:
	for event: ItemEvent in events:
		var key: String = "%s:%d" % [event.def_id, event.reason]
		if _pending_items.has(key):
			_pending_items[key].count_delta += event.count_delta
		else:
			_pending_items[key] = ItemEvent.create(0, event.def_id, event.count_delta, event.reason)


# Cierra lo agregado en una GAMEPLAY con un id de [param take]. true si no había nada o se ha cerrado; false (sin
# tocar nada) si no hay id.
func _close_aggregate(take: Callable) -> bool:
	if _pending_ledger.is_empty() and _pending_items.is_empty():
		return true
	var id: int = take.call()
	if id == 0:
		return false
	var op: EconomyOp = EconomyOp.create(id, EconomyOp.Kind.GAMEPLAY)
	for key: String in _pending_ledger:
		var entry: LedgerEntry = _pending_ledger[key]
		_ledger_balance[entry.currency] += entry.delta
		entry.balance_after = _ledger_balance[entry.currency]
		op.ledger.append(entry)
	for key: String in _pending_items:
		if _pending_items[key].count_delta != 0:
			op.items.append(_pending_items[key])
	_pending_ledger.clear()
	_pending_items.clear()
	if not op.is_empty():
		_append(op)
	return true


func _live() -> Live:
	if not live_source.is_valid():
		return null
	var value: Variant = live_source.call()
	return value as Live if value is Live else null


# Lo del cuerpo pasa al registro (la foto de este guardado).
func _apply_live(live: Live) -> void:
	if live != null:
		if not live.location.is_empty():
			record.location = live.location.duplicate()
		record.health = live.health
		record.active_weapon_slot = live.active_weapon_slot
		record.played_seconds = maxi(record.played_seconds, live.played_seconds)
		if live.now_unix > 0:
			for key: String in record.timers.keys():
				if record.timers[key] <= live.now_unix:
					record.timers.erase(key)
	record.active_weapon_slot = _effective_active_slot(record.active_weapon_slot)


# La ranura activa que se guarda (§8): la del cuerpo y, si no tiene arma y la otra sí, la otra (I10).
func _effective_active_slot(slot: int) -> int:
	slot = clampi(slot, 0, InventoryState.OPEN_EQUIPMENT_SLOTS - 1)
	var equipment: int = InventoryState.ContainerId.EQUIPMENT
	if record.inventory.get_item(equipment, slot) == null and record.inventory.get_item(equipment, 1 - slot) != null:
		return 1 - slot
	return slot


# Lo que is_dirty compara: los campos del registro, la revisión del inventario y lo del cuerpo.
func _snapshot(live: Live) -> Dictionary:
	var location: Dictionary = record.location
	var health: int = record.health
	var slot: int = record.active_weapon_slot
	if live != null:
		if not live.location.is_empty():
			location = live.location
		health = live.health
		slot = live.active_weapon_slot
	return {
		"level": record.level, "xp_total": record.xp_total, "realm_points": record.realm_points,
		"starter_granted": record.starter_granted, "bag_slots": record.bag_slots,
		"active_weapon_slot": _effective_active_slot(slot), "wallets": record.wallets.duplicate(),
		"revision": revision, "timers": record.timers.duplicate(), "location": location.duplicate(),
		"health": health,
	}


static func _differs(now: Dictionary, confirmed: Dictionary) -> bool:
	for key: String in ["level", "xp_total", "realm_points", "starter_granted", "bag_slots", "active_weapon_slot",
			"wallets", "revision", "timers", "health"]:
		if now.get(key) != confirmed.get(key):
			return true
	var here: Dictionary = now.get("location", {})
	var there: Dictionary = confirmed.get("location", {})
	if here.is_empty() or there.is_empty():
		return here.is_empty() != there.is_empty()
	if here.get("zone_id") != there.get("zone_id") or here.get("channel") != there.get("channel"):
		return true
	var a := Vector3(float(here.get("x", 0.0)), float(here.get("y", 0.0)), float(here.get("z", 0.0)))
	var b := Vector3(float(there.get("x", 0.0)), float(there.get("y", 0.0)), float(there.get("z", 0.0)))
	return a.distance_to(b) >= MOVE_EPSILON_M
