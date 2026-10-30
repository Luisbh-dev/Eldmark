class_name ClientInventory
extends RefCounted
## El inventario del jugador local en el cliente (docs/progresion.md §11.3, UI-26): la intención optimista y su
## reversión. Guarda el [b]estado confirmado[/b] (lo último que dijo el servidor), la lista de [b]peticiones
## pendientes[/b] (las enviadas sin respuesta, [constant MAX_PENDING] como mucho) y una [b]vista[/b], que es el
## confirmado con las pendientes aplicadas por [method InventoryOps.apply], la misma función que usa el servidor
## para decidir: las dos validan igual.
## [br][br]
## [b]Flujo.[/b]
## [br]1. [method request]: se valida en local sobre la vista con el [InventoryOps.Context] del personaje
## ([member context_provider]: nivel, ranura activa, «puede tocar el equipo» y «bebiendo» del estado predicho).
## Si falla, [signal request_rejected] con el texto del código y no se envía nada.
## [br]2. Si vale, sale un INVENTORY_REQUEST con el siguiente [code]request_id[/code] ([member send_request]),
## se añade a pendientes y la vista cambia al instante. La pila nueva de un SPLIT lleva un [code]uid[/code]
## provisional negativo (−[code]request_id[/code]) y no se puede tocar hasta que el delta trae el real.
## [br]3. [method on_delta]: sus entradas se aplican al confirmado en orden de llegada; si responde a una
## petición, sale de pendientes. Se rehace la vista; una pendiente que ya no vale en local deja de aplicarse
## (su respuesta llegará igual).
## [br]4. Un rechazo trae el contenido real de las ranuras: aplicado al confirmado, el objeto vuelve a su
## casilla y sale [signal request_rejected] con el texto del código.
## [br]5. [method tick]: sin respuesta en [constant RESPONSE_TIMEOUT_MSEC] ms se vacían las pendientes y se pide
## un INVENTORY_SYNC_REQUEST ([member send_sync]); el FULL lo rehace todo.
## [br][br]
## [b]Revisión.[/b] Un delta aplicado ([code]result[/code] 0) cuya revisión no es la confirmada + 1 hace pedir
## sincronía. Las páginas de INVENTORY_FULL ([method on_full_page]) se juntan por revisión
## ([method ProgressMessages.InventoryFull.assemble]) y solo entonces sustituyen el confirmado. Las peticiones de
## sincronía van una cada [constant SYNC_INTERVAL_MSEC] ms como mucho (más, el servidor suma un aviso).
## [br][br]
## [b]No es optimista[/b] el arma en las manos, la barra de acciones ni las cargas: cambian con el estado
## confirmado del combate (LOADOUT y el estado propio), un RTT después, así un rechazo nunca hace parpadear el
## arma. Esta clase no toca el [CombatState].
## [br][br]
## [b]Gestos[/b] (§11.2): [method make_move], [method make_split], [method make_destroy] y [method equip_target]
## construyen la petición de cada gesto con el [code]uid[/code] que se ve en el origen.
## [br][br]
## Sin red ni nodos: [NetClient] la alimenta y le da con qué enviar; las pruebas, con funciones propias. El reloj
## llega en [method tick]. Solo cliente.

## La vista cambió (petición enviada, delta, página completa, plazo vencido).
signal view_changed
## El estado confirmado cambió (delta o FULL).
signal confirmed_changed
## Una petición no se envió (falla en local) o el servidor la rechazó: [param text] es el aviso en español.
signal request_rejected(result: int, text: String)

## Peticiones sin respuesta como mucho: con estas en vuelo, la interfaz espera.
const MAX_PENDING: int = 8
## Plazo de una respuesta (ms). En un canal fiable no debería vencer nunca.
const RESPONSE_TIMEOUT_MSEC: int = 5000
## Tiempo mínimo (ms) entre dos INVENTORY_SYNC_REQUEST (docs/progresion.md §4.6).
const SYNC_INTERVAL_MSEC: int = 5000
## [code]request_id[/code] más alto (u16); después vuelve a 1 (el 0 es «cambio del servidor»).
const MAX_REQUEST_ID: int = 0xFFFF
## Revisión del inventario: u32 que da la vuelta.
const REVISION_MASK: int = 0xFFFFFFFF


## Una petición enviada sin respuesta.
class Pending:
	var id: int = 0
	var request: InventoryOps.Request = null
	## Definición del objeto del origen al enviarla (para el «Necesitas nivel N» de un rechazo).
	var def_id: StringName = &""
	var sent_msec: int = 0
	## Se sigue aplicando en la vista (false: ya no vale en local y solo se espera su respuesta).
	var active: bool = true


## [code](ProgressMessages.InventoryRequest) -> bool[/code]: envía el mensaje; false si no se pudo.
var send_request: Callable = Callable()
## [code]() -> bool[/code]: envía un INVENTORY_SYNC_REQUEST; false si no se pudo.
var send_sync: Callable = Callable()
## [code]() -> InventoryOps.Context[/code]: el contexto del personaje ahora (sin él, el de por defecto: nivel 1,
## WEAPON_1 activa y libre para tocar el equipo). [member InventoryOps.Context.new_uid] lo pone esta clase.
var context_provider: Callable = Callable()
## [code]() -> bool[/code]: si el personaje está en combate (el texto de NOT_NOW cambia).
var in_combat_provider: Callable = Callable()
## Definiciones (null = [method ItemDatabase.shared]).
var db: ItemDatabase = null

var _confirmed: InventoryState = null
var _view: InventoryState = null
var _revision: int = 0
var _pending: Array[Pending] = []
var _next_request_id: int = 1
# Páginas del INVENTORY_FULL que se está juntando (por índice) y su revisión (−1 = ninguna).
var _pages: Dictionary[int, ProgressMessages.InventoryFull] = {}
var _pages_revision: int = -1
var _now_msec: int = 0
var _sync_wanted: bool = false
var _awaiting_full: bool = false
var _last_sync_msec: int = -SYNC_INTERVAL_MSEC
# Contadores para las pruebas y la depuración.
var _requests_sent: int = 0
var _local_rejections: int = 0
var _server_rejections: int = 0
var _syncs_sent: int = 0
var _timeouts: int = 0
var _revision_gaps: int = 0
var _deltas_ignored: int = 0


# --- Consultas ------------------------------------------------------------------------------------

## true desde que llega el primer INVENTORY_FULL completo (antes no hay inventario que enseñar).
func has_inventory() -> bool:
	return _confirmed != null


## La vista: el confirmado con las pendientes aplicadas (null sin inventario). No se debe cambiar.
func get_view() -> InventoryState:
	return _view


## Lo último que dijo el servidor (null sin inventario). No se debe cambiar.
func get_confirmed() -> InventoryState:
	return _confirmed


## Revisión del confirmado.
func get_revision() -> int:
	return _revision


## Peticiones enviadas sin respuesta (también las que ya no se aplican en la vista).
func get_pending_count() -> int:
	return _pending.size()


## Los [code]request_id[/code] de las pendientes, en orden de envío.
func get_pending_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for pending: Pending in _pending:
		ids.append(pending.id)
	return ids


## true mientras se espera el INVENTORY_FULL de una sincronía (o se quiere pedir).
func is_syncing() -> bool:
	return _awaiting_full or _sync_wanted


## true si la instancia [param item] es una pila creada en local que aún no tiene su [code]uid[/code] real.
static func is_provisional(item: ItemInstance) -> bool:
	return item != null and item.uid < 0


## Contadores: [code]requests_sent[/code], [code]local_rejections[/code], [code]server_rejections[/code],
## [code]syncs_sent[/code], [code]timeouts[/code], [code]revision_gaps[/code] y [code]deltas_ignored[/code]
## (antes del primer FULL).
func get_stats() -> Dictionary:
	return {
		"requests_sent": _requests_sent, "local_rejections": _local_rejections,
		"server_rejections": _server_rejections, "syncs_sent": _syncs_sent, "timeouts": _timeouts,
		"revision_gaps": _revision_gaps, "deltas_ignored": _deltas_ignored,
	}


## El contexto del personaje ahora, sin ids (el de [member context_provider] o el de por defecto).
func current_context() -> InventoryOps.Context:
	var context: InventoryOps.Context = null
	if context_provider.is_valid():
		context = context_provider.call() as InventoryOps.Context
	if context == null:
		context = InventoryOps.Context.new()
	context.db = _db()
	context.new_uid = Callable()
	return context


# --- Gestos -------------------------------------------------------------------------------------

## MOVE de [param from] a [param to] ([code](contenedor, ranura)[/code]) con el [code]uid[/code] que se ve en
## el origen (0 si está vacío: el servidor diría STALE y aquí no se envía).
func make_move(from: Vector2i, to: Vector2i) -> InventoryOps.Request:
	return InventoryOps.make_request(InventoryOps.Op.MOVE, from.x, from.y, to.x, to.y, 0, _uid_at(from))


## SPLIT de [param count] unidades de [param from] a la ranura vacía [param to] de la bolsa.
func make_split(from: Vector2i, to: Vector2i, count: int) -> InventoryOps.Request:
	return InventoryOps.make_request(InventoryOps.Op.SPLIT, from.x, from.y, to.x, to.y, count, _uid_at(from))


## DESTROY de [param count] unidades de [param from] (0 = toda la pila).
func make_destroy(from: Vector2i, count: int = 0) -> InventoryOps.Request:
	return InventoryOps.make_request(InventoryOps.Op.DESTROY, from.x, from.y, InventoryOps.NO_SLOT,
			InventoryOps.NO_SLOT, count, _uid_at(from))


## Dónde va el objeto de [param from] con un doble clic o un clic derecho (§11.2): desde la bolsa, un arma a
## WEAPON_2 si está vacía y si no a la ranura de arma que no está activa, y una armadura a su ranura; desde el
## equipo, a la primera ranura libre de la bolsa. [code](−1, −1)[/code] si no hay a dónde (un objeto que no se
## equipa, la ranura vacía o la bolsa llena).
func equip_target(from: Vector2i) -> Vector2i:
	var none := Vector2i(-1, -1)
	if _view == null:
		return none
	var item: ItemInstance = _view.get_item(from.x, from.y)
	if item == null:
		return none
	if from.x == InventoryState.ContainerId.EQUIPMENT:
		var free: int = _view.first_free(InventoryState.ContainerId.BAG)
		return Vector2i(InventoryState.ContainerId.BAG, free) if free >= 0 else none
	var definition: ItemDefinition = _db().get_definition(item.def_id)
	if definition == null or not definition.is_equipable():
		return none
	var equipment: int = InventoryState.ContainerId.EQUIPMENT
	if definition.equip_slot != ItemDefinition.EquipSlot.WEAPON:
		return Vector2i(equipment, int(definition.equip_slot))
	if _view.get_item(equipment, InventoryState.EquipmentSlot.WEAPON_2) == null:
		return Vector2i(equipment, InventoryState.EquipmentSlot.WEAPON_2)
	var active: int = clampi(current_context().active_weapon_slot, 0, 1)
	return Vector2i(equipment, 1 - active)


# --- Peticiones -----------------------------------------------------------------------------------

## Valida [param op] en local y, si vale, la envía y la aplica en la vista. Devuelve el resultado local
## ([enum InventoryOps.Result]; OK = enviada). Sin inventario, NOT_NOW; con [constant MAX_PENDING] en vuelo,
## RATE; tocar una pila provisional, NOT_NOW; si no se puede enviar, NOT_NOW. Todo lo que no es OK emite
## [signal request_rejected] con su texto.
func request(op: InventoryOps.Request) -> int:
	if op == null or _view == null:
		return _reject_locally(InventoryOps.Result.NOT_NOW)
	if _pending.size() >= MAX_PENDING:
		return _reject_locally(InventoryOps.Result.RATE)
	if _touches_provisional(op):
		return _reject_locally(InventoryOps.Result.NOT_NOW)
	var id: int = _next_request_id
	var trial: InventoryState = _view.duplicate_state()
	var outcome: InventoryOps.Outcome = InventoryOps.apply(trial, op, _context_for(id))
	if not outcome.is_ok():
		return _reject_locally(outcome.result, outcome.required_level)
	var message: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.from_request(id, op)
	if not send_request.is_valid() or not bool(send_request.call(message)):
		return _reject_locally(InventoryOps.Result.NOT_NOW)
	_next_request_id = id + 1 if id < MAX_REQUEST_ID else 1
	var pending := Pending.new()
	pending.id = id
	pending.request = op
	var source: ItemInstance = _view.get_item(op.from_container, op.from_slot)
	pending.def_id = source.def_id if source != null else &""
	pending.sent_msec = _now_msec
	_pending.append(pending)
	_requests_sent += 1
	_view = trial
	view_changed.emit()
	return InventoryOps.Result.OK


## Lo que diría [method request] de [param op] ahora, sin enviar nada, sin cambiar la vista y sin avisar (para
## que un gesto con diálogo, como dividir o destruir, no lo abra si la petición no va a valer).
func validate(op: InventoryOps.Request) -> int:
	if op == null or _view == null:
		return InventoryOps.Result.NOT_NOW
	if _pending.size() >= MAX_PENDING:
		return InventoryOps.Result.RATE
	if _touches_provisional(op):
		return InventoryOps.Result.NOT_NOW
	return InventoryOps.apply(_view.duplicate_state(), op, _context_for(_next_request_id)).result


## Avisa de [param result] como un rechazo local ([signal request_rejected] con su texto) sin enviar nada: para
## un gesto que no llega a ser petición (desequipar con la bolsa llena). Devuelve [param result].
func notify_rejected(result: int) -> int:
	return _reject_locally(result)


## Un INVENTORY_DELTA: sus entradas al confirmado (las ranuras que este cliente no tiene se ignoran), la
## revisión, la pendiente a la que responde y, si es un rechazo, el aviso. Antes del primer FULL no hace nada
## (el FULL lo traerá todo).
func on_delta(delta: ProgressMessages.InventoryDelta) -> void:
	if delta == null:
		return
	if _confirmed == null:
		_deltas_ignored += 1
		return
	for entry: ProgressMessages.Entry in delta.entries:
		if _confirmed.has_slot(entry.container, entry.slot):
			_confirmed.set_item(entry.container, entry.slot, entry.item)
	if delta.result == InventoryOps.Result.OK:
		if delta.revision != (_revision + 1) & REVISION_MASK:
			_revision_gaps += 1
			_want_sync()
		_revision = delta.revision
	if delta.request_id != 0:
		var index: int = _pending_index(delta.request_id)
		var pending: Pending = _pending[index] if index >= 0 else null
		if index >= 0:
			_pending.remove_at(index)
		if delta.result != InventoryOps.Result.OK:
			_server_rejections += 1
			var level: int = _required_level_of(pending.def_id) if pending != null else 0
			request_rejected.emit(delta.result, _text(delta.result, level))
	confirmed_changed.emit()
	_rebuild_view()


## Una página de INVENTORY_FULL. Junta las de la misma revisión (una de otra revisión empieza de nuevo) y,
## completas, sustituyen el confirmado; si no se pueden juntar, se pide otra sincronía.
func on_full_page(page: ProgressMessages.InventoryFull) -> void:
	if page == null:
		return
	if page.revision != _pages_revision:
		_pages.clear()
		_pages_revision = page.revision
	_pages[page.page_index] = page
	if _pages.size() < page.page_count:
		return
	var pages: Array[ProgressMessages.InventoryFull] = []
	for index: int in _pages:
		pages.append(_pages[index])
	_pages.clear()
	_pages_revision = -1
	var state: InventoryState = ProgressMessages.InventoryFull.assemble(pages)
	if state == null:
		_want_sync()
		return
	_confirmed = state
	_revision = page.revision
	_awaiting_full = false
	_sync_wanted = false
	confirmed_changed.emit()
	_rebuild_view()


## Avanza el reloj a [param now_msec] (ms): vence el plazo de las pendientes y manda la sincronía que espera.
func tick(now_msec: int) -> void:
	_now_msec = now_msec
	if not _pending.is_empty() and now_msec - _pending[0].sent_msec >= RESPONSE_TIMEOUT_MSEC:
		_timeouts += 1
		_pending.clear()
		_want_sync()
		if _confirmed != null:
			_rebuild_view()
	if _awaiting_full and now_msec - _last_sync_msec >= RESPONSE_TIMEOUT_MSEC:
		# El FULL no llegó: se vuelve a pedir.
		_sync_wanted = true
	_flush_sync()


## Olvida el inventario (fin de la sesión).
func clear() -> void:
	_confirmed = null
	_view = null
	_revision = 0
	_pending.clear()
	_pages.clear()
	_pages_revision = -1
	_sync_wanted = false
	_awaiting_full = false
	view_changed.emit()


# --- Interno ------------------------------------------------------------------------------------

func _db() -> ItemDatabase:
	return db if db != null else ItemDatabase.shared()


func _uid_at(position: Vector2i) -> int:
	if _view == null:
		return 0
	var item: ItemInstance = _view.get_item(position.x, position.y)
	return item.uid if item != null else 0


# El contexto de la petición [param id]: el del personaje con los ids provisionales −id.
func _context_for(id: int) -> InventoryOps.Context:
	var context: InventoryOps.Context = current_context()
	context.new_uid = func() -> int: return -id
	return context


func _touches_provisional(op: InventoryOps.Request) -> bool:
	if is_provisional(_view.get_item(op.from_container, op.from_slot)):
		return true
	return op.op != InventoryOps.Op.DESTROY and is_provisional(_view.get_item(op.to_container, op.to_slot))


func _reject_locally(result: int, required_level: int = 0) -> int:
	_local_rejections += 1
	request_rejected.emit(result, _text(result, required_level))
	return result


func _text(result: int, required_level: int) -> String:
	var in_combat: bool = in_combat_provider.is_valid() and bool(in_combat_provider.call())
	return InventoryOps.result_text(result, required_level, in_combat)


# Nivel que pide la definición [param def_id] si el personaje no llega (para «Necesitas nivel N»); 0 si llega.
func _required_level_of(def_id: StringName) -> int:
	var definition: ItemDefinition = _db().get_definition(def_id) if def_id != &"" else null
	if definition == null:
		return 0
	return definition.required_level if definition.required_level > current_context().level else 0


func _pending_index(id: int) -> int:
	for index: int in range(_pending.size()):
		if _pending[index].id == id:
			return index
	return -1


# La vista de nuevo: el confirmado con las pendientes que aún valen, en orden de envío.
func _rebuild_view() -> void:
	var view: InventoryState = _confirmed.duplicate_state()
	for pending: Pending in _pending:
		if not pending.active:
			continue
		var outcome: InventoryOps.Outcome = InventoryOps.apply(view, pending.request, _context_for(pending.id))
		if not outcome.is_ok():
			pending.active = false
	_view = view
	view_changed.emit()


func _want_sync() -> void:
	_sync_wanted = true
	_flush_sync()


func _flush_sync() -> void:
	if not _sync_wanted or _now_msec - _last_sync_msec < SYNC_INTERVAL_MSEC:
		return
	if not send_sync.is_valid() or not bool(send_sync.call()):
		return
	_sync_wanted = false
	_awaiting_full = true
	_last_sync_msec = _now_msec
	_syncs_sent += 1
