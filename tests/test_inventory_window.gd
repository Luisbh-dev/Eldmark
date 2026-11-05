extends TestCase
## The inventory and character windows (docs/progression.md §11 and §15, P6; UI-26): [InventoryWindow],
## [CharacterWindow], [InventorySlotView] and [SplitDialog] over a [ClientInventory] with the squire's kit. The
## simulated gestures (drag and drop, Shift to split, double click and right click, drop outside) produce the
## right request, or the notice without sending anything; the slots show the view, the tooltip and the coins; the
## character window, its slots, the level, the XP and the figure with its appearance; and the [HUD] mounts them with I and C, warns in the
## chat and removes the template selector from the death screen when there is an inventory.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const OWN_ID: int = 101
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"


## Network client that connects to nothing: its inventory is the real one and what it sends is recorded.
class FakeClient extends NetClient:
	var fake_config: ClientConfig = ClientConfig.new()
	var fake_character: PlayerCharacter = null
	var requests: Array[ProgressMessages.InventoryRequest] = []
	var syncs: int = 0

	func get_config() -> ClientConfig:
		return fake_config

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_net_id() -> int:
		return OWN_ID

	func send_inventory_request(message: ProgressMessages.InventoryRequest) -> bool:
		requests.append(message)
		return true

	func send_inventory_sync_request() -> bool:
		syncs += 1
		return true

	func inventory_context() -> InventoryOps.Context:
		var context := InventoryOps.Context.new()
		context.level = get_progress().get_level()
		return context


var _nodes: Array[Node] = []
var _db: ItemDatabase
var _state: InventoryState
var _inventory: ClientInventory
var _progress: ClientProgress
var _sent: Array[ProgressMessages.InventoryRequest] = []
var _rejections: Array[Array] = []
var _window: InventoryWindow
var _character: CharacterWindow
var _split: SplitDialog
var _destroy: UIConfirmDialog


func before_each() -> void:
	InputBindings.ensure_defaults()
	_db = ItemDatabase.shared()
	_sent.clear()
	_rejections.clear()
	_state = InventoryState.new()
	var ids: Array[int] = [100]
	StarterKit.grant(_state, &"squire", _db, func() -> int:
		ids[0] += 1
		return ids[0])
	_inventory = ClientInventory.new()
	_inventory.send_request = func(message: ProgressMessages.InventoryRequest) -> bool:
		_sent.append(message)
		return true
	_inventory.request_rejected.connect(func(result: int, text: String) -> void: _rejections.append([result, text]))
	_inventory.on_full_page(ProgressMessages.InventoryFull.split(1, _state)[0])
	_progress = ClientProgress.new()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_track(root)
	# Side by side, as in the HUD (not centered: they do not overlap).
	_window = InventoryWindow.new()
	_window.centered = false
	_window.position = Vector2(620.0, 40.0)
	root.add_child(_window)
	_character = CharacterWindow.new()
	_character.centered = false
	_character.position = Vector2(10.0, 40.0)
	root.add_child(_character)
	_split = SplitDialog.new()
	root.add_child(_split)
	_destroy = UIConfirmDialog.new()
	root.add_child(_destroy)
	_window.bind(_inventory, _progress, _split, _destroy)
	_character.bind(_inventory, _progress, _window)


func after_each() -> void:
	_inventory.send_request = Callable()
	for connection: Dictionary in _inventory.request_rejected.get_connections():
		_inventory.request_rejected.disconnect(connection["callable"])
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _track(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _slot_of(def_id: StringName) -> Vector2i:
	for position: Vector2i in _state.occupied_slots():
		if _state.get_item(position.x, position.y).def_id == def_id:
			return position
	return Vector2i(-1, -1)


func _view_of(position: Vector2i) -> InventorySlotView:
	if position.x == InventoryState.ContainerId.EQUIPMENT:
		return _character.get_slot_view(position.y)
	return _window.get_slot_view(position.y)


func _last_sent() -> Array:
	var message: ProgressMessages.InventoryRequest = _sent.back()
	return [message.op, message.from_container, message.from_slot, message.to_container, message.to_slot,
			message.count, message.expected_uid]


func _click(button: MouseButton, double_click: bool = false) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.double_click = double_click
	event.position = Vector2(10.0, 10.0)
	return event


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = true
	return event


# --- Ventana de inventario --------------------------------------------------------------------------

func test_the_bag_grid_shows_the_view_and_the_wallet() -> void:
	assert_eq(_window.get_slot_count(), InventoryState.BAG_SLOTS_DEFAULT, "one slot per bag slot")
	assert_eq((_window.get_slot_view(0).get_parent() as GridContainer).columns, InventoryWindow.COLUMNS,
			"seis columnas")
	var potion: Vector2i = _slot_of(&"potion_health")
	var view_slot: InventorySlotView = _view_of(potion)
	var item: ItemInstance = _state.get_item(potion.x, potion.y)
	assert_eq(view_slot.get_item().uid, item.uid, "the slot shows its item")
	assert_eq(view_slot.count, item.count, "with its stack")
	assert_eq(view_slot.get_count_text(), str(item.count) if item.count > 1 else "")
	assert_eq(view_slot.rarity, 0, "common border")
	assert_true(view_slot.icon is GameIcon, "the potion carries the ART-12 drawing, not a letter")
	# Whatever has no drawing (armor, for example) keeps the placeholder box with its short name.
	var plain := ItemDefinition.new()
	plain.display_name = "Poción de vida"
	plain.category = ItemDefinition.Category.MISC
	var icon: PlaceholderIcon = InventorySlotView.icon_for(plain) as PlaceholderIcon
	if assert_not_null(icon, "without a drawing, the placeholder"):
		assert_eq(icon.letter, "PV", "short name of \"Poción de vida\" (Health Potion)")
		assert_eq(icon.color, InventorySlotView.CATEGORY_COLORS[ItemDefinition.Category.MISC],
				"with the color of its category")
	assert_eq(view_slot.get_tooltip_content()["title"], "Poción de vida")
	assert_null(_window.get_slot_view(InventoryState.BAG_SLOTS_DEFAULT - 1).get_item(), "the last one, empty")
	assert_eq(_window.get_slot_view(InventoryState.BAG_SLOTS_DEFAULT - 1).get_tooltip_content(), {},
			"an empty bag slot has no tooltip")
	# The coins, from the progress.
	assert_eq(_window.get_gold_label().text, "Oro: 0")
	_progress.on_wallet(ProgressMessages.WalletUpdate.make(Currency.Code.GOLD, 1250000, 50, EconomyReason.NPC_KILL))
	_progress.on_wallet(ProgressMessages.WalletUpdate.make(Currency.Code.MERITS, 42, 0, 0))
	assert_eq(_window.get_gold_label().text, "Oro: 1.250.000", "with thousands separators")
	assert_eq(_window.get_merits_label().text, "Méritos: 42")
	# A bigger bag (a FULL with more slots) gives more slots; and a smaller one, fewer.
	var bigger: InventoryState = _state.duplicate_state()
	bigger.bag_slots = 36
	_inventory.on_full_page(ProgressMessages.InventoryFull.split(2, bigger)[0])
	assert_eq(_window.get_slot_count(), 36)
	_inventory.on_full_page(ProgressMessages.InventoryFull.split(3, _state)[0])
	assert_eq(_window.get_slot_count(), InventoryState.BAG_SLOTS_DEFAULT)
	await wait_process_frames()


func test_dragging_onto_another_slot_sends_a_move() -> void:
	var bow: Vector2i = _slot_of(&"bow_vado")
	var bow_uid: int = _state.get_item(bow.x, bow.y).uid
	var target: int = InventoryState.BAG_SLOTS_DEFAULT - 1
	var data: Dictionary = _view_of(bow).make_drag_data(false)
	assert_eq(data[InventorySlotView.DRAG_KEY], bow)
	assert_eq(data["uid"], bow_uid)
	assert_true(_window.get_slot_view(target).accepts(data), "otra casilla lo acepta")
	assert_false(_view_of(bow).accepts(data), "the same slot does not")
	_window.get_slot_view(target)._drop_data(Vector2.ZERO, data)
	assert_eq(_sent.size(), 1, "one request")
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, bow.x, bow.y, 0, target, 0, bow_uid], "MOVE with the uid that is shown")
	assert_eq(_window.get_slot_view(target).get_item().uid, bow_uid, "optimistic: the bow is already in place")
	assert_null(_view_of(bow).get_item(), "and its slot, empty")
	# From the bag to the character window: equip the bow in WEAPON_2.
	data = _window.get_slot_view(target).make_drag_data(false)
	_character.get_slot_view(InventoryState.EquipmentSlot.WEAPON_2).drop(data)
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, 0, target, 1, 1, 0, bow_uid], "equipping is a MOVE to the equipment")
	assert_eq(_character.get_slot_view(1).get_item().uid, bow_uid, "the weapon slot already shows it")
	# The armor slots accept nothing; a local piece that is not valid does not go out (WEAPON_REQUIRED).
	var head: InventorySlotView = _character.get_slot_view(InventoryState.EquipmentSlot.HEAD)
	assert_false(head.accepts(_character.get_slot_view(1).make_drag_data(false)), "the head is closed")
	# Dropping the bow from WEAPON_2 onto WEAPON_1 swaps them.
	var sword_uid: int = _character.get_slot_view(0).get_item().uid
	_character.get_slot_view(0).drop(_character.get_slot_view(1).make_drag_data(false))
	assert_eq(_sent.size(), 3, "swapping the weapons goes out")
	assert_eq(_character.get_slot_view(0).get_item().uid, bow_uid, "the bow in WEAPON_1")
	assert_eq(_character.get_slot_view(1).get_item().uid, sword_uid, "the sword in WEAPON_2")
	# Leaving the active slot (WEAPON_1) empty does not go out; the other one does.
	_window.get_slot_view(target).drop(_character.get_slot_view(0).make_drag_data(false))
	assert_eq(_sent.size(), 3, "leaving the active slot empty does not go out")
	assert_eq(_rejections.back(), [InventoryOps.Result.WEAPON_REQUIRED, "Necesitas un arma en la mano"])
	_window.get_slot_view(target).drop(_character.get_slot_view(1).make_drag_data(false))
	assert_eq(_sent.size(), 4, "unequipping the WEAPON_2 one goes out")
	assert_null(_character.get_slot_view(1).get_item())
	assert_eq(_window.get_slot_view(target).get_item().uid, sword_uid)
	await wait_process_frames()


func test_shift_dragging_opens_the_split_dialog_with_half() -> void:
	var potion: Vector2i = _slot_of(&"potion_health")
	var item: ItemInstance = _state.get_item(potion.x, potion.y)
	var target: int = InventoryState.BAG_SLOTS_DEFAULT - 1
	var data: Dictionary = _view_of(potion).make_drag_data(true)
	assert_true(bool(data["split"]), "with Shift, split")
	_window.get_slot_view(target).drop(data)
	assert_true(_split.is_open(), "the dialog opens")
	assert_true(_sent.is_empty(), "and nothing goes out yet")
	assert_eq(_split.get_amount(), SplitDialog.default_amount(item.count), "by default, half")
	assert_eq(int(_split.get_spin_box().max_value), item.count - 1, "at most, the stack minus one")
	assert_eq(_split.get_message_label().text, "¿Cuántas separas de Poción de vida ×%d?" % item.count)
	_split.set_amount(item.count - 1)
	_split.confirm()
	assert_false(_split.is_open())
	assert_eq(_last_sent(), [InventoryOps.Op.SPLIT, potion.x, potion.y, 0, target, item.count - 1, item.uid],
			"SPLIT with the chosen amount")
	var provisional: ItemInstance = _window.get_slot_view(target).get_item()
	assert_true(ClientInventory.is_provisional(provisional), "the new stack, provisional")
	assert_false(_window.get_slot_view(target).enabled, "y apagada")
	assert_eq(_window.get_slot_view(target).make_drag_data(false), {}, "it is not dragged until it has its uid")
	# Cancelling sends nothing.
	var stamina: Vector2i = _slot_of(&"potion_stamina")
	_window.get_slot_view(target - 1).drop(_view_of(stamina).make_drag_data(true))
	assert_true(_split.is_open())
	_split.cancel()
	assert_eq(_sent.size(), 1, "cancelar no pide nada")
	# Splitting something that does not stack does not open the dialog: the notice says why and nothing goes out.
	var bow: Vector2i = _slot_of(&"bow_vado")
	_window.get_slot_view(target - 2).drop(_view_of(bow).make_drag_data(true))
	assert_false(_split.is_open(), "a bow is not split")
	assert_eq(_rejections.back(), [InventoryOps.Result.INVALID, "Petición no válida"])
	assert_eq(_sent.size(), 1)
	# Nor onto an occupied slot.
	_view_of(bow).drop(_view_of(stamina).make_drag_data(true))
	assert_false(_split.is_open())
	assert_eq(_rejections.back(), [InventoryOps.Result.NO_ROOM, "No cabe"])
	await wait_process_frames()


func test_double_click_and_right_click_equip_and_unequip() -> void:
	var bow: Vector2i = _slot_of(&"bow_vado")
	var bow_uid: int = _state.get_item(bow.x, bow.y).uid
	# Double click on the bow in the bag: to WEAPON_2, which is empty.
	_view_of(bow)._gui_input(_click(MOUSE_BUTTON_LEFT, true))
	assert_eq(_sent.size(), 1)
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, bow.x, bow.y, 1, 1, 0, bow_uid], "equipar en WEAPON_2")
	# Right click on the already equipped bow (the optimistic view): to the first free slot in the bag.
	var free: int = _inventory.get_view().first_free(InventoryState.ContainerId.BAG)
	_character.get_slot_view(1)._gui_input(_click(MOUSE_BUTTON_RIGHT))
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, 1, 1, 0, free, 0, bow_uid], "unequip to the bag")
	# The sword is the active weapon: unequipping it warns and does not go out.
	_character.get_slot_view(0)._gui_input(_click(MOUSE_BUTTON_RIGHT))
	assert_eq(_sent.size(), 2)
	assert_eq(_rejections.back()[0], InventoryOps.Result.WEAPON_REQUIRED)
	# A potion is not equipped: nothing.
	var potion: Vector2i = _slot_of(&"potion_health")
	assert_eq(_window.activate_item(potion), -1)
	assert_eq(_sent.size(), 2, "a potion is not equipped")
	# A single click does nothing beyond what UIIconSlot does.
	var pressed: Array[int] = [0]
	_view_of(potion).pressed.connect(func() -> void: pressed[0] += 1)
	var release := _click(MOUSE_BUTTON_LEFT)
	release.pressed = false
	_view_of(potion)._gui_input(release)
	assert_eq(pressed[0], 1, "un clic sigue siendo «pressed»")
	assert_eq(_sent.size(), 2)
	await wait_process_frames()


func test_dropping_outside_the_windows_asks_before_destroying() -> void:
	var potion: Vector2i = _slot_of(&"potion_health")
	var item: ItemInstance = _state.get_item(potion.x, potion.y)
	assert_true(_window.drop_outside(potion), "a potion can be destroyed")
	assert_true(_destroy.is_open(), "confirmation is requested")
	assert_true(_destroy.get_message_label().text.begins_with("¿Destruir Poción de vida ×%d?" % item.count),
			"«%s»" % _destroy.get_message_label().text)
	assert_true(_sent.is_empty(), "nada sale hasta confirmar")
	_destroy.confirm()
	assert_eq(_last_sent(), [InventoryOps.Op.DESTROY, potion.x, potion.y, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT,
			item.count, item.uid], "DESTROY of the whole stack with its uid")
	assert_null(_view_of(potion).get_item(), "optimistic: the stack disappears")
	# Cancelar no destruye.
	var stamina: Vector2i = _slot_of(&"potion_stamina")
	assert_true(_window.drop_outside(stamina))
	_destroy.cancel()
	assert_eq(_sent.size(), 1)
	# What cannot be destroyed does not ask: the notice and nothing else.
	var bow: Vector2i = _slot_of(&"bow_vado")
	assert_false(_window.drop_outside(bow), "the Ford's bow is indestructible")
	assert_false(_destroy.is_open())
	assert_eq(_rejections.back(), [InventoryOps.Result.LOCKED, "Ese objeto no se puede destruir"])
	assert_false(_window.drop_outside(Vector2i(1, 0)), "lo equipado tampoco")
	assert_eq(_sent.size(), 1)
	assert_eq(InventoryWindow.destroy_question(_state.get_item(bow.x, bow.y)), "¿Destruir Arco del Vado?",
			"no quantity for what does not stack")
	# Inside the windows nothing is destroyed; outside, it is.
	await wait_process_frames()
	_character.open()
	_window.open()
	await wait_process_frames()
	assert_true(_window.is_over_drop_zone(_window.get_global_rect().get_center()), "over the inventory")
	assert_true(_window.is_over_drop_zone(_character.get_global_rect().get_center()), "over the character")
	assert_false(_window.is_over_drop_zone(Vector2(-500.0, -500.0)), "outside both")
	assert_false(_window.get_global_rect().intersects(_character.get_global_rect()), "they do not overlap")
	_character.close()
	assert_false(_window.is_over_drop_zone(_character.get_global_rect().get_center()), "a closed window does not count")
	_window.close()


func test_the_slot_tooltip_tells_damage_level_and_comparison() -> void:
	var bow: Vector2i = _slot_of(&"bow_vado")
	var bow_item: ItemInstance = _state.get_item(bow.x, bow.y)
	var sword_item: ItemInstance = _state.get_item(1, 0)
	var content: Dictionary = InventorySlotView.tooltip_for(bow_item, _db, 1, sword_item)
	assert_eq(content["title"], "Arco del Vado")
	assert_eq(content["subtitle"], "Arma · Ranura de arma")
	var body: String = content["body"]
	var damage: Dictionary = InventorySlotView.weapon_damage(CombatCatalog.weapon_id(&"bow"))
	assert_true(int(damage["heavy"]) > 0, "the bow has a drawn shot with damage")
	assert_true(body.contains(InventorySlotView.TEXT_HEAVY % int(damage["heavy"])), "the fort's damage: %s" % body)
	assert_true(body.contains("Frente a Espada y escudo del Vado"), "the comparison with the weapon in that slot")
	assert_true(body.contains(InventorySlotView.TEXT_BOUND), "ligado")
	assert_true(body.contains("Valor: 0 de oro"))
	assert_true(body.contains("Nivel requerido: 1"))
	assert_false(body.contains("[color=#%s]Nivel requerido" % UIPalette.DANGER.to_html(false)),
			"nivel 1 alcanzado: no va en rojo")
	# With a weapon that requires a higher level, the line is red.
	var strong: ItemDefinition = _db.get_definition(&"bow_vado").duplicate() as ItemDefinition
	strong.id = &"test_strong_bow"
	strong.required_level = 20
	var db: ItemDatabase = ItemDatabase.build_from_definitions([strong] as Array[ItemDefinition],
			CombatCatalog.tables())
	var strong_item: ItemInstance = ItemInstance.create(9, strong, 1)
	var red: String = InventorySlotView.tooltip_for(strong_item, db, 5)["body"]
	assert_true(red.contains("[color=#%s]Nivel requerido: 20[/color]" % UIPalette.DANGER.to_html(false)),
			"en rojo si no llega: %s" % red)
	# A potion states its effect.
	var potion: Vector2i = _slot_of(&"potion_health")
	var potion_body: String = InventorySlotView.tooltip_for(_state.get_item(potion.x, potion.y), _db, 1)["body"]
	assert_true(potion_body.contains(CombatText.ability_description(CombatCatalog.ability_id(&"potion_health"))),
			"the potion's effect")
	# A bag slot with a weapon compares with the slot it would go to on a double click.
	assert_true(String(_view_of(bow).get_tooltip_content()["body"]).contains("Frente a") == false,
			"with WEAPON_2 empty there is nothing to compare against")
	assert_eq(InventorySlotView.short_name("Arco del Vado"), "AV")
	assert_eq(InventorySlotView.short_name("Poción"), "P")
	assert_eq(InventorySlotView.short_name("  "), "?")


# --- Ventana de personaje ---------------------------------------------------------------------------

func test_the_character_window_shows_slots_sheet_and_figure() -> void:
	for slot: int in range(InventoryState.EQUIPMENT_SLOTS):
		var view_slot: InventorySlotView = _character.get_slot_view(slot)
		assert_eq(view_slot.get_position_key(), Vector2i(1, slot))
		assert_eq(view_slot.locked, slot >= InventoryState.OPEN_EQUIPMENT_SLOTS, "ranura %d" % slot)
	var locked: InventorySlotView = _character.get_slot_view(InventoryState.EquipmentSlot.CHEST)
	assert_eq(locked.get_tooltip_content()["subtitle"], CharacterWindow.TEXT_SOON, "\"Próximamente\" (Coming soon)")
	assert_false(locked.enabled, "en gris")
	assert_eq(_character.get_slot_view(0).get_item().def_id, &"sword_shield_vado", "the sword in WEAPON_1")
	assert_null(_character.get_slot_view(1).get_item(), "WEAPON_2 empty")
	assert_eq(_character.get_slot_view(1).get_tooltip_content()["title"], "Arma 2")
	# Level, XP and points from the progress; the CombatRules sheet.
	var curve: LevelCurve = LevelCurve.shared()
	_progress.on_progress(ProgressMessages.ProgressUpdate.make(curve, 3, curve.total_to(3) + 25, 25,
			ProgressMessages.XpSource.PVP, 120, 0))
	assert_eq(_character.get_level_label().text, "Nivel 3")
	assert_eq(_character.get_xp_label().text, "25 / %d XP" % curve.xp_for_next(3))
	assert_near(_character.get_xp_bar().value, 25.0 / float(curve.xp_for_next(3)), 0.0001)
	assert_eq(_character.get_realm_points_label().text, "Puntos de reino: 120")
	assert_eq(_character.get_attribute_label().text, "Puntos de atributo: 2")
	assert_eq(_character.get_health_label().text, "Vida máxima: %d" % CombatCatalog.rules().health_max)
	_progress.on_progress(ProgressMessages.ProgressUpdate.make(curve, curve.level_cap, curve.total_to(curve.level_cap),
			0, ProgressMessages.XpSource.STATE, 120, 0))
	assert_eq(_character.get_xp_label().text, CharacterWindow.TEXT_XP_CAP)
	# The figure: with the appearance (Vardheim's default if the 8 B are 0) and the weapons.
	var zeros := PackedByteArray()
	zeros.resize(CharacterAppearance.ENCODED_SIZE)
	_character.set_identity("Ana", VARDHEIM, zeros)
	assert_eq(_character.get_name_label().text, "Ana")
	assert_null(_character.get_preview_visual(), "the figure is not mounted until opened")
	_character.open()
	var visual: HumanoidVisual = _character.get_preview_visual()
	if not assert_not_null(visual, "on opening, the figure"):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var expected: CharacterAppearance = AppearanceApplier.resolve(zeros, VARDHEIM, catalog)
	assert_eq(visual.get_tint(&"skin"), catalog.skin_tones[expected.skin].color, "with the skin of its appearance")
	assert_true(_character.get_preview_viewport().own_world_3d, "in its own world")
	var bow_id: int = CombatCatalog.weapon_id(&"bow")
	_character.set_weapons(bow_id, 0)
	assert_eq(_character.get_preview_character().combat.weapon_id, bow_id, "with the active weapon")
	var yaw: float = _character.get_preview_yaw()
	_character.rotate_preview(100.0)
	assert_near(_character.get_preview_yaw(), yaw + 100.0 * CharacterWindow.TURN_RATE, 0.0001, "rotates when dragged")
	await wait_process_frames(2)
	_character.close()
	assert_eq(_character.get_preview_viewport().render_target_update_mode, SubViewport.UPDATE_DISABLED,
			"cerrada no dibuja")
	_character.open()
	assert_eq(_character.get_preview_visual(), visual, "on reopening, the same figure")
	_character.close()


# --- HUD ----------------------------------------------------------------------------------------

func test_the_hud_mounts_the_windows_with_i_and_c() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.fake_config.display_name = "Ana"
	client.fake_config.realm = VARDHEIM
	var rig: CameraRig = _track((load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate()) as CameraRig
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	client.fake_character = character
	hud.bind(character, rig)
	assert_null(hud.get_inventory_window(), "the sandbox has no inventory")
	hud.bind_net(client, null)
	var inventory_window: InventoryWindow = hud.get_inventory_window()
	var character_window: CharacterWindow = hud.get_character_window()
	if not assert_not_null(inventory_window, "over the network, yes") or not assert_not_null(character_window):
		return
	assert_true(inventory_window.get_index() < hud.get_death_screen().get_index(), "below the death screen")
	assert_true(hud.get_split_dialog().get_index() > inventory_window.get_index(), "dialogs on top")
	assert_eq(inventory_window.get_inventory(), client.get_inventory(), "with the client's inventory")
	# I and C open both at once and release the cursor.
	tree.root.push_input(_key(KEY_I))
	assert_true(inventory_window.is_open(), "I opens the inventory")
	tree.root.push_input(_key(KEY_C))
	assert_true(character_window.is_open(), "C opens the character one")
	assert_true(inventory_window.is_open(), "both at once")
	assert_true(rig.is_ui_holding_cursor(), "with the cursor free")
	tree.root.push_input(_key(KEY_I))
	assert_false(inventory_window.is_open(), "I closes it")
	character_window.close()
	assert_false(rig.is_ui_holding_cursor())
	# A gesture with the client's inventory goes out through the client; a notice, to the chat.
	client.get_inventory().on_full_page(ProgressMessages.InventoryFull.split(1, _state)[0])
	var bow: Vector2i = _slot_of(&"bow_vado")
	assert_eq(inventory_window.activate_item(bow), InventoryOps.Result.OK)
	assert_eq(client.requests.size(), 1, "the request goes out through the client")
	var chat_lines: int = hud.get_chat().get_log().get_count()
	inventory_window.drop_outside(Vector2i(1, 0))
	assert_eq(hud.get_chat().get_log().get_count(), chat_lines + 1, "the rejection notice, in the chat")
	# With an inventory, the death screen offers no template.
	hud._open_death_screen()
	assert_false(hud.get_death_screen().get_template_selector().visible, "without a template selector")
	hud.get_death_screen().close()
	# With the death screen open, I opens nothing.
	hud.get_death_screen().open("", 0, PackedStringArray())
	assert_false(hud.toggle_inventory_window(), "muerto no")
	hud.get_death_screen().close()
	# A second call rebuilds the windows without duplicating them.
	hud.bind_net(client, null)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is InventoryWindow).size(), 1)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is CharacterWindow).size(), 1)
	await wait_process_frames()


func test_without_inventory_the_death_screen_keeps_the_template_selector() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.fake_config.realm = VARDHEIM
	var rig: CameraRig = _track((load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate()) as CameraRig
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	hud.bind(character, rig)
	hud.bind_net(client, null)
	hud._open_death_screen()
	assert_true(hud.get_death_screen().get_template_selector().visible,
			"without an inventory (server without progress), the template is still chosen")
	hud.get_death_screen().close()
	await wait_process_frames()
