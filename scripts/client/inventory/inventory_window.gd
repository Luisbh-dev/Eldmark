class_name InventoryWindow
extends UIWindow
## Ventana de inventario (tecla I; docs/progresion.md §11, UI-26): la bolsa en una rejilla de
## [constant COLUMNS] columnas con [member InventoryState.bag_slots] casillas ([InventorySlotView]) y, al pie,
## el oro y los méritos. Enseña la [b]vista[/b] de [ClientInventory] (lo confirmado con las peticiones en vuelo)
## y se rehace con cada cambio.
## [br][br]
## [b]Gestos[/b] (§11.2), también los de las casillas de la [CharacterWindow], que pasan por aquí:
## [br]- arrastrar y soltar en otra casilla: MOVE (mover, juntar, intercambiar, equipar, desequipar);
## [br]- con Mayúsculas: SPLIT, con el [SplitDialog] (por defecto, la mitad) si la división vale;
## [br]- doble clic o clic derecho: equipar desde la bolsa o desequipar a la primera ranura libre
## ([method ClientInventory.equip_target]);
## [br]- soltar fuera de las ventanas ([method add_drop_zone]): DESTROY tras un [UIConfirmDialog]
## («¿Destruir Poción de vida ×3?»), si la destrucción vale.
## [br]Toda petición se valida antes en local con la misma regla que el servidor: si no vale, el aviso sale por
## [signal ClientInventory.request_rejected] y no se envía nada (ni se abre el diálogo).
## [br][br]
## Las dos ventanas usan [UIWindow]: se abren a la vez y liberan el cursor. Solo cliente.

const TEXT_TITLE: String = "Inventario"
const TEXT_LOADING: String = "Cargando el inventario…"
const TEXT_DESTROY_TITLE: String = "Destruir objeto"
const TEXT_DESTROY_QUESTION: String = "¿Destruir %s?"
const TEXT_DESTROY_HINT: String = "No se puede deshacer."
const TEXT_DESTROY_BUTTON: String = "Destruir"
const TEXT_CANCEL: String = "Cancelar"
## Columnas de la rejilla de la bolsa.
const COLUMNS: int = 6
## Filas que se ven sin desplazar (con más ranuras, la rejilla se desplaza).
const VISIBLE_ROWS: int = 6
const SLOT_GAP: int = 4

var _inventory: ClientInventory = null
var _progress: ClientProgress = null
var _db: ItemDatabase = null
var _split_dialog: SplitDialog = null
var _destroy_dialog: UIConfirmDialog = null
var _scroll: ScrollContainer = null
var _grid: GridContainer = null
var _slots: Array[InventorySlotView] = []
var _loading_label: Label = null
var _gold_label: Label = null
var _merits_label: Label = null
var _drop_zones: Array[Control] = []
# Lo que espera el diálogo abierto: origen y destino de la división, y origen, uid y cantidad de la destrucción.
var _split_from: Vector2i = Vector2i(-1, -1)
var _split_to: Vector2i = Vector2i(-1, -1)
var _split_uid: int = 0
var _destroy_from: Vector2i = Vector2i(-1, -1)
var _destroy_uid: int = 0
var _destroy_count: int = 0


func _init() -> void:
	super()
	name = "InventoryWindow"
	window_title = TEXT_TITLE
	var content: VBoxContainer = get_content()
	_loading_label = Label.new()
	_loading_label.name = "Cargando"
	_loading_label.theme_type_variation = &"DimLabel"
	_loading_label.text = TEXT_LOADING
	content.add_child(_loading_label)
	_scroll = ScrollContainer.new()
	_scroll.name = "Bolsa"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var step: float = UIIconSlot.SLOT_SIZE.y + SLOT_GAP
	_scroll.custom_minimum_size = Vector2(COLUMNS * (UIIconSlot.SLOT_SIZE.x + SLOT_GAP) + 12.0,
			VISIBLE_ROWS * step)
	content.add_child(_scroll)
	_grid = GridContainer.new()
	_grid.name = "Rejilla"
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override(&"h_separation", SLOT_GAP)
	_grid.add_theme_constant_override(&"v_separation", SLOT_GAP)
	_scroll.add_child(_grid)
	content.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	footer.name = "Monedas"
	footer.add_theme_constant_override(&"separation", 18)
	content.add_child(footer)
	_gold_label = Label.new()
	_gold_label.name = "Oro"
	footer.add_child(_gold_label)
	_merits_label = Label.new()
	_merits_label.name = "Meritos"
	footer.add_child(_merits_label)
	_ensure_slot_count(InventoryState.BAG_SLOTS_DEFAULT)
	_refresh_wallet()


func _ready() -> void:
	super()
	var tooltip: UITooltip = UITooltip.get_shared(get_tree())
	for view: InventorySlotView in _slots:
		view.bind_tooltip(tooltip)


## Conecta la ventana con el inventario [param inventory] y el progreso [param progress] del jugador, y con los
## diálogos de dividir y de destruir (que viven fuera de la ventana: son modales a pantalla completa).
## [param db] son las definiciones (null = [method ItemDatabase.shared]).
func bind(inventory: ClientInventory, progress: ClientProgress, split_dialog: SplitDialog,
		destroy_dialog: UIConfirmDialog, db: ItemDatabase = null) -> void:
	if _inventory != null and _inventory.view_changed.is_connected(refresh):
		_inventory.view_changed.disconnect(refresh)
	if _progress != null and _progress.changed.is_connected(refresh):
		_progress.changed.disconnect(refresh)
	_inventory = inventory
	_progress = progress
	_db = db
	if _inventory != null:
		_inventory.view_changed.connect(refresh)
	if _progress != null:
		_progress.changed.connect(refresh)
	if _split_dialog != split_dialog:
		_split_dialog = split_dialog
		if _split_dialog != null:
			_split_dialog.confirmed.connect(_on_split_confirmed)
	if _destroy_dialog != destroy_dialog:
		_destroy_dialog = destroy_dialog
		if _destroy_dialog != null:
			_destroy_dialog.confirmed.connect(_on_destroy_confirmed)
	refresh()


## Además de esta ventana, [param control] cuenta como «dentro» al soltar un arrastre (la ventana de
## personaje): soltar fuera de todas es destruir.
func add_drop_zone(control: Control) -> void:
	if control != null and not _drop_zones.has(control):
		_drop_zones.append(control)


func get_inventory() -> ClientInventory:
	return _inventory


## La casilla [param slot] de la bolsa (null si no existe).
func get_slot_view(slot: int) -> InventorySlotView:
	return _slots[slot] if slot >= 0 and slot < _slots.size() else null


## Casillas de la bolsa que hay ahora.
func get_slot_count() -> int:
	return _slots.size()


func get_gold_label() -> Label:
	return _gold_label


func get_merits_label() -> Label:
	return _merits_label


## Rehace las casillas y las monedas con la vista del inventario.
func refresh() -> void:
	var view: InventoryState = _inventory.get_view() if _inventory != null else null
	_loading_label.visible = view == null
	_ensure_slot_count(view.bag_slots if view != null else InventoryState.BAG_SLOTS_DEFAULT)
	for view_slot: InventorySlotView in _slots:
		present_slot(view_slot)
	_refresh_wallet()


## Pone en [param view_slot] lo que la vista tiene en su ranura, con el nivel del personaje y, para un arma de la
## bolsa, la de la ranura a la que iría con un doble clic para la comparación del tooltip. La usa también la
## [CharacterWindow] para sus casillas.
func present_slot(view_slot: InventorySlotView) -> void:
	var view: InventoryState = _inventory.get_view() if _inventory != null else null
	var level: int = _progress.get_level() if _progress != null else 1
	if view == null:
		view_slot.show_item(null, _db, level)
		return
	var position: Vector2i = view_slot.get_position_key()
	var item: ItemInstance = view.get_item(position.x, position.y)
	var compare: ItemInstance = null
	if item != null and position.x == InventoryState.ContainerId.BAG:
		var target: Vector2i = _inventory.equip_target(position)
		if target.x == InventoryState.ContainerId.EQUIPMENT:
			compare = view.get_item(target.x, target.y)
	view_slot.show_item(item, _db, level, compare)


## Conecta los gestos de [param view_slot] (de esta ventana o de la de personaje) con los de esta ventana.
func connect_slot(view_slot: InventorySlotView) -> void:
	view_slot.drop_handler = drop_item
	view_slot.activated.connect(func() -> void: activate_item(view_slot.get_position_key()))
	view_slot.drag_cancelled.connect(func() -> void: handle_drag_cancelled(view_slot.get_position_key()))


# --- Gestos -------------------------------------------------------------------------------------

## Soltar lo de [param from] en [param to]: MOVE, o con [param split] el diálogo de dividir (si la división de
## la mitad vale; si no, el aviso de por qué). Devuelve el resultado local de la petición (OK también cuando
## abre el diálogo) o −1 si no hay nada que hacer.
func drop_item(from: Vector2i, to: Vector2i, split: bool) -> int:
	if _inventory == null or from == to:
		return -1
	if not split:
		return _inventory.request(_inventory.make_move(from, to))
	var view: InventoryState = _inventory.get_view()
	var item: ItemInstance = view.get_item(from.x, from.y) if view != null else null
	var amount: int = SplitDialog.default_amount(item.count) if item != null else 1
	var op: InventoryOps.Request = _inventory.make_split(from, to, amount)
	if _inventory.validate(op) != InventoryOps.Result.OK or _split_dialog == null:
		# Sin diálogo (o si no vale): se pide la mitad tal cual, que avisa del motivo si no vale.
		return _inventory.request(op)
	_split_from = from
	_split_to = to
	_split_uid = item.uid
	_split_dialog.open(_display_name(item, _db).get_slice(" ×", 0), item.count)
	return InventoryOps.Result.OK


## Doble clic o clic derecho en [param at]: equipar o desequipar ([method ClientInventory.equip_target]).
## Devuelve el resultado local, o −1 si el objeto no se equipa o la casilla está vacía.
func activate_item(at: Vector2i) -> int:
	if _inventory == null or _inventory.get_view() == null:
		return -1
	var item: ItemInstance = _inventory.get_view().get_item(at.x, at.y)
	if item == null:
		return -1
	var target: Vector2i = _inventory.equip_target(at)
	if target.x < 0:
		if at.x == InventoryState.ContainerId.EQUIPMENT:
			return _inventory.notify_rejected(InventoryOps.Result.NO_ROOM)
		return -1
	return _inventory.request(_inventory.make_move(at, target))


## Un arrastre desde [param from] acabó sin que nadie lo recogiera: si el ratón está fuera de las ventanas, se
## pide confirmación para destruirlo ([method drop_outside]).
func handle_drag_cancelled(from: Vector2i) -> bool:
	if is_over_drop_zone(get_global_mouse_position()):
		return false
	return drop_outside(from)


## Soltar lo de [param from] fuera de las ventanas: si la destrucción de toda la pila vale, abre la confirmación
## y devuelve true; si no, avisa del motivo y devuelve false.
func drop_outside(from: Vector2i) -> bool:
	if _inventory == null or _inventory.get_view() == null:
		return false
	var item: ItemInstance = _inventory.get_view().get_item(from.x, from.y)
	if item == null or ClientInventory.is_provisional(item):
		return false
	var op: InventoryOps.Request = _inventory.make_destroy(from, item.count)
	if _inventory.validate(op) != InventoryOps.Result.OK:
		_inventory.request(op)
		return false
	if _destroy_dialog == null:
		return _inventory.request(op) == InventoryOps.Result.OK
	_destroy_from = from
	_destroy_uid = item.uid
	_destroy_count = item.count
	_destroy_dialog.open(TEXT_DESTROY_TITLE, "%s\n%s" % [destroy_question(item, _db), TEXT_DESTROY_HINT],
			TEXT_DESTROY_BUTTON, TEXT_CANCEL, true)
	return true


## «¿Destruir Poción de vida ×3?» (la cantidad solo en lo que se apila).
static func destroy_question(item: ItemInstance, db: ItemDatabase = null) -> String:
	return TEXT_DESTROY_QUESTION % _display_name(item, db)


## true si [param point] (pantalla) cae dentro de esta ventana o de una de [method add_drop_zone] visibles.
func is_over_drop_zone(point: Vector2) -> bool:
	var zones: Array[Control] = [self]
	zones.append_array(_drop_zones)
	for zone: Control in zones:
		if is_instance_valid(zone) and zone.is_visible_in_tree() and zone.get_global_rect().has_point(point):
			return true
	return false


# --- Interno ------------------------------------------------------------------------------------

func _on_split_confirmed(amount: int) -> void:
	if _inventory == null or _split_from.x < 0:
		return
	var op := InventoryOps.make_request(InventoryOps.Op.SPLIT, _split_from.x, _split_from.y, _split_to.x,
			_split_to.y, amount, _split_uid)
	_split_from = Vector2i(-1, -1)
	_inventory.request(op)


func _on_destroy_confirmed() -> void:
	if _inventory == null or _destroy_from.x < 0:
		return
	var op := InventoryOps.make_request(InventoryOps.Op.DESTROY, _destroy_from.x, _destroy_from.y,
			InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, _destroy_count, _destroy_uid)
	_destroy_from = Vector2i(-1, -1)
	_inventory.request(op)


static func _display_name(item: ItemInstance, db: ItemDatabase = null) -> String:
	if item == null:
		return ""
	var definition: ItemDefinition = (db if db != null else ItemDatabase.shared()).get_definition(item.def_id)
	if definition == null:
		return String(item.def_id)
	return "%s ×%d" % [definition.display_name, item.count] if definition.max_stack > 1 else definition.display_name


func _ensure_slot_count(count: int) -> void:
	while _slots.size() > count:
		var last: InventorySlotView = _slots.pop_back()
		_grid.remove_child(last)
		last.queue_free()
	while _slots.size() < count:
		var view_slot := InventorySlotView.new()
		view_slot.container = InventoryState.ContainerId.BAG
		view_slot.slot = _slots.size()
		view_slot.name = "Casilla%d" % view_slot.slot
		connect_slot(view_slot)
		_grid.add_child(view_slot)
		_slots.append(view_slot)
		if is_inside_tree():
			view_slot.bind_tooltip(UITooltip.get_shared(get_tree()))


func _refresh_wallet() -> void:
	var gold: int = _progress.get_balance(Currency.Code.GOLD) if _progress != null else 0
	var merits: int = _progress.get_balance(Currency.Code.MERITS) if _progress != null else 0
	_gold_label.text = "%s: %s" % [Currency.display_name(Currency.Code.GOLD), _thousands(gold)]
	_merits_label.text = "%s: %s" % [Currency.display_name(Currency.Code.MERITS), _thousands(merits)]


## [param value] con puntos de millar («1.250.000»).
static func _thousands(value: int) -> String:
	var digits: String = str(absi(value))
	var groups: PackedStringArray = PackedStringArray()
	while digits.length() > 3:
		groups.insert(0, digits.right(3))
		digits = digits.left(digits.length() - 3)
	groups.insert(0, digits)
	return ("-" if value < 0 else "") + ".".join(groups)
