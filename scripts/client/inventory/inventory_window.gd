class_name InventoryWindow
extends UIWindow
## Inventory window (key I; docs/progression.md §11, UI-26): the bag in a grid of
## [constant COLUMNS] columns with [member InventoryState.bag_slots] slots ([InventorySlotView]) and, at the bottom,
## gold and merits. It shows the [b]view[/b] of [ClientInventory] (what is confirmed plus the requests in flight)
## and is rebuilt on every change.
## [br][br]
## [b]Gestures[/b] (§11.2), including those of the [CharacterWindow] slots, which go through here:
## [br]- drag and drop onto another slot: MOVE (move, merge, swap, equip, unequip);
## [br]- with Shift: SPLIT, with the [SplitDialog] (half by default) if the split is valid;
## [br]- double click or right click: equip from the bag or unequip to the first free slot
## ([method ClientInventory.equip_target]);
## [br]- drop outside the windows ([method add_drop_zone]): DESTROY after a [UIConfirmDialog]
## ("¿Destruir Poción de vida ×3?", Destroy Health Potion ×3?), if the destruction is valid.
## [br]Every request is first validated locally with the same rule as the server: if it is not valid, the notice comes out through
## [signal ClientInventory.request_rejected] and nothing is sent (nor is the dialog opened).
## [br][br]
## Both windows use [UIWindow]: they open together and release the cursor. Client only.

const TEXT_TITLE: String = "Inventario"
const TEXT_LOADING: String = "Cargando el inventario…"
const TEXT_DESTROY_TITLE: String = "Destruir objeto"
const TEXT_DESTROY_QUESTION: String = "¿Destruir %s?"
const TEXT_DESTROY_HINT: String = "No se puede deshacer."
const TEXT_DESTROY_BUTTON: String = "Destruir"
const TEXT_CANCEL: String = "Cancelar"
## Columns of the bag grid.
const COLUMNS: int = 6
## Rows visible without scrolling (with more slots, the grid scrolls).
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
# What the open dialog expects: source and destination of the split, and source, uid and quantity of the destruction.
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


## Connects the window to the player's inventory [param inventory] and progress [param progress], and to the
## split and destroy dialogs (which live outside the window: they are full-screen modals).
## [param db] are the definitions (null = [method ItemDatabase.shared]).
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


## Besides this window, [param control] counts as "inside" when dropping a drag (the character
## window): dropping outside all of them means destroying.
func add_drop_zone(control: Control) -> void:
	if control != null and not _drop_zones.has(control):
		_drop_zones.append(control)


func get_inventory() -> ClientInventory:
	return _inventory


## Bag slot [param slot] (null if it does not exist).
func get_slot_view(slot: int) -> InventorySlotView:
	return _slots[slot] if slot >= 0 and slot < _slots.size() else null


## Bag slots there are now.
func get_slot_count() -> int:
	return _slots.size()


func get_gold_label() -> Label:
	return _gold_label


func get_merits_label() -> Label:
	return _merits_label


## Rebuilds the slots and the coins from the inventory view.
func refresh() -> void:
	var view: InventoryState = _inventory.get_view() if _inventory != null else null
	_loading_label.visible = view == null
	_ensure_slot_count(view.bag_slots if view != null else InventoryState.BAG_SLOTS_DEFAULT)
	for view_slot: InventorySlotView in _slots:
		present_slot(view_slot)
	_refresh_wallet()


## Puts in [param view_slot] what the view has in its slot, with the character's level and, for a bag
## weapon, that of the slot it would go to on a double click for the tooltip comparison. It is also used by the
## [CharacterWindow] for its slots.
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


## Connects the gestures of [param view_slot] (from this window or the character one) to those of this window.
func connect_slot(view_slot: InventorySlotView) -> void:
	view_slot.drop_handler = drop_item
	view_slot.activated.connect(func() -> void: activate_item(view_slot.get_position_key()))
	view_slot.drag_cancelled.connect(func() -> void: handle_drag_cancelled(view_slot.get_position_key()))


# --- Gestures -----------------------------------------------------------------------------------

## Drops what is at [param from] onto [param to]: MOVE, or with [param split] the split dialog (if the split of
## half is valid; if not, the notice about why). Returns the request's local result (OK also when
## it opens the dialog) or −1 if there is nothing to do.
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
		# Without a dialog (or if it is not valid): half is requested as is, which notifies the reason if it is not valid.
		return _inventory.request(op)
	_split_from = from
	_split_to = to
	_split_uid = item.uid
	_split_dialog.open(_display_name(item, _db).get_slice(" ×", 0), item.count)
	return InventoryOps.Result.OK


## Double click or right click at [param at]: equip or unequip ([method ClientInventory.equip_target]).
## Returns the local result, or −1 if the item is not equippable or the slot is empty.
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


## A drag from [param from] ended without anyone picking it up: if the mouse is outside the windows,
## confirmation is asked to destroy it ([method drop_outside]).
func handle_drag_cancelled(from: Vector2i) -> bool:
	if is_over_drop_zone(get_global_mouse_position()):
		return false
	return drop_outside(from)


## Drops what is at [param from] outside the windows: if destroying the whole stack is valid, opens the confirmation
## and returns true; if not, notifies the reason and returns false.
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


## "¿Destruir Poción de vida ×3?" (Destroy Health Potion ×3?) (the quantity only for what stacks).
static func destroy_question(item: ItemInstance, db: ItemDatabase = null) -> String:
	return TEXT_DESTROY_QUESTION % _display_name(item, db)


## true if [param point] (screen) falls inside this window or one of the visible [method add_drop_zone] ones.
func is_over_drop_zone(point: Vector2) -> bool:
	var zones: Array[Control] = [self]
	zones.append_array(_drop_zones)
	for zone: Control in zones:
		if is_instance_valid(zone) and zone.is_visible_in_tree() and zone.get_global_rect().has_point(point):
			return true
	return false


# --- Internal -------------------------------------------------------------------------------------

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


## [param value] with thousands separators ("1.250.000").
static func _thousands(value: int) -> String:
	var digits: String = str(absi(value))
	var groups: PackedStringArray = PackedStringArray()
	while digits.length() > 3:
		groups.insert(0, digits.right(3))
		digits = digits.left(digits.length() - 3)
	groups.insert(0, digits)
	return ("-" if value < 0 else "") + ".".join(groups)
