extends TestCase
## Las ventanas de inventario y de personaje (docs/progresion.md §11 y §15, P6; UI-26): [InventoryWindow],
## [CharacterWindow], [InventorySlotView] y [SplitDialog] sobre un [ClientInventory] con el kit del escudero. Los
## gestos simulados (arrastrar y soltar, Mayúsculas para dividir, doble clic y clic derecho, soltar fuera) generan la
## petición correcta, o el aviso sin enviar nada; las casillas enseñan la vista, el tooltip y las monedas; la ventana
## de personaje, sus ranuras, el nivel, la XP y la figura con su apariencia; y el [HUD] las monta con I y C, avisa en el
## chat y quita el selector de plantilla de la pantalla de muerte cuando hay inventario.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const OWN_ID: int = 101
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"


## Cliente de red que no conecta con nada: su inventario es el de verdad y lo que envía se apunta.
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
	# Una al lado de la otra, como en el HUD (sin centrar: no se solapan).
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
	assert_eq(_window.get_slot_count(), InventoryState.BAG_SLOTS_DEFAULT, "una casilla por ranura de la bolsa")
	assert_eq((_window.get_slot_view(0).get_parent() as GridContainer).columns, InventoryWindow.COLUMNS,
			"seis columnas")
	var potion: Vector2i = _slot_of(&"potion_health")
	var view_slot: InventorySlotView = _view_of(potion)
	var item: ItemInstance = _state.get_item(potion.x, potion.y)
	assert_eq(view_slot.get_item().uid, item.uid, "la casilla enseña su objeto")
	assert_eq(view_slot.count, item.count, "con su pila")
	assert_eq(view_slot.get_count_text(), str(item.count) if item.count > 1 else "")
	assert_eq(view_slot.rarity, 0, "borde de común")
	var icon: PlaceholderIcon = view_slot.icon as PlaceholderIcon
	if assert_not_null(icon, "sin icono de ART-12, el provisional"):
		assert_eq(icon.letter, "PV", "nombre corto de «Poción de vida»")
		assert_eq(icon.color, InventorySlotView.CATEGORY_COLORS[ItemDefinition.Category.CONSUMABLE],
				"con el color de su categoría")
	assert_eq(view_slot.get_tooltip_content()["title"], "Poción de vida")
	assert_null(_window.get_slot_view(InventoryState.BAG_SLOTS_DEFAULT - 1).get_item(), "la última, vacía")
	assert_eq(_window.get_slot_view(InventoryState.BAG_SLOTS_DEFAULT - 1).get_tooltip_content(), {},
			"una casilla vacía de la bolsa no tiene tooltip")
	# Las monedas, del progreso.
	assert_eq(_window.get_gold_label().text, "Oro: 0")
	_progress.on_wallet(ProgressMessages.WalletUpdate.make(Currency.Code.GOLD, 1250000, 50, EconomyReason.NPC_KILL))
	_progress.on_wallet(ProgressMessages.WalletUpdate.make(Currency.Code.MERITS, 42, 0, 0))
	assert_eq(_window.get_gold_label().text, "Oro: 1.250.000", "con puntos de millar")
	assert_eq(_window.get_merits_label().text, "Méritos: 42")
	# Una bolsa más grande (un FULL con más ranuras) da más casillas; y una más pequeña, menos.
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
	assert_false(_view_of(bow).accepts(data), "la misma casilla no")
	_window.get_slot_view(target)._drop_data(Vector2.ZERO, data)
	assert_eq(_sent.size(), 1, "una petición")
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, bow.x, bow.y, 0, target, 0, bow_uid], "MOVE con el uid que se ve")
	assert_eq(_window.get_slot_view(target).get_item().uid, bow_uid, "optimista: el arco ya está en su sitio")
	assert_null(_view_of(bow).get_item(), "y su casilla, vacía")
	# De la bolsa a la ventana de personaje: equipar el arco en WEAPON_2.
	data = _window.get_slot_view(target).make_drag_data(false)
	_character.get_slot_view(InventoryState.EquipmentSlot.WEAPON_2).drop(data)
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, 0, target, 1, 1, 0, bow_uid], "equipar es un MOVE al equipo")
	assert_eq(_character.get_slot_view(1).get_item().uid, bow_uid, "la ranura de arma ya lo enseña")
	# Las ranuras de armadura no reciben nada; una pieza local que no vale no sale (WEAPON_REQUIRED).
	var head: InventorySlotView = _character.get_slot_view(InventoryState.EquipmentSlot.HEAD)
	assert_false(head.accepts(_character.get_slot_view(1).make_drag_data(false)), "la cabeza está cerrada")
	# Soltar el arco de WEAPON_2 sobre WEAPON_1 los intercambia.
	var sword_uid: int = _character.get_slot_view(0).get_item().uid
	_character.get_slot_view(0).drop(_character.get_slot_view(1).make_drag_data(false))
	assert_eq(_sent.size(), 3, "intercambiar las armas sale")
	assert_eq(_character.get_slot_view(0).get_item().uid, bow_uid, "el arco en WEAPON_1")
	assert_eq(_character.get_slot_view(1).get_item().uid, sword_uid, "la espada en WEAPON_2")
	# Dejar vacía la ranura activa (WEAPON_1) no sale; la otra, sí.
	_window.get_slot_view(target).drop(_character.get_slot_view(0).make_drag_data(false))
	assert_eq(_sent.size(), 3, "dejar vacía la ranura activa no sale")
	assert_eq(_rejections.back(), [InventoryOps.Result.WEAPON_REQUIRED, "Necesitas un arma en la mano"])
	_window.get_slot_view(target).drop(_character.get_slot_view(1).make_drag_data(false))
	assert_eq(_sent.size(), 4, "desequipar la de WEAPON_2 sale")
	assert_null(_character.get_slot_view(1).get_item())
	assert_eq(_window.get_slot_view(target).get_item().uid, sword_uid)
	await wait_process_frames()


func test_shift_dragging_opens_the_split_dialog_with_half() -> void:
	var potion: Vector2i = _slot_of(&"potion_health")
	var item: ItemInstance = _state.get_item(potion.x, potion.y)
	var target: int = InventoryState.BAG_SLOTS_DEFAULT - 1
	var data: Dictionary = _view_of(potion).make_drag_data(true)
	assert_true(bool(data["split"]), "con Mayúsculas, dividir")
	_window.get_slot_view(target).drop(data)
	assert_true(_split.is_open(), "se abre el diálogo")
	assert_true(_sent.is_empty(), "y aún no sale nada")
	assert_eq(_split.get_amount(), SplitDialog.default_amount(item.count), "por defecto, la mitad")
	assert_eq(int(_split.get_spin_box().max_value), item.count - 1, "como mucho, la pila menos una")
	assert_eq(_split.get_message_label().text, "¿Cuántas separas de Poción de vida ×%d?" % item.count)
	_split.set_amount(item.count - 1)
	_split.confirm()
	assert_false(_split.is_open())
	assert_eq(_last_sent(), [InventoryOps.Op.SPLIT, potion.x, potion.y, 0, target, item.count - 1, item.uid],
			"SPLIT con la cantidad elegida")
	var provisional: ItemInstance = _window.get_slot_view(target).get_item()
	assert_true(ClientInventory.is_provisional(provisional), "la pila nueva, provisional")
	assert_false(_window.get_slot_view(target).enabled, "y apagada")
	assert_eq(_window.get_slot_view(target).make_drag_data(false), {}, "no se arrastra hasta tener su uid")
	# Cancelar no envía nada.
	var stamina: Vector2i = _slot_of(&"potion_stamina")
	_window.get_slot_view(target - 1).drop(_view_of(stamina).make_drag_data(true))
	assert_true(_split.is_open())
	_split.cancel()
	assert_eq(_sent.size(), 1, "cancelar no pide nada")
	# Dividir lo que no se apila no abre el diálogo: el aviso de por qué y nada sale.
	var bow: Vector2i = _slot_of(&"bow_vado")
	_window.get_slot_view(target - 2).drop(_view_of(bow).make_drag_data(true))
	assert_false(_split.is_open(), "un arco no se divide")
	assert_eq(_rejections.back(), [InventoryOps.Result.INVALID, "Petición no válida"])
	assert_eq(_sent.size(), 1)
	# Ni sobre una casilla ocupada.
	_view_of(bow).drop(_view_of(stamina).make_drag_data(true))
	assert_false(_split.is_open())
	assert_eq(_rejections.back(), [InventoryOps.Result.NO_ROOM, "No cabe"])
	await wait_process_frames()


func test_double_click_and_right_click_equip_and_unequip() -> void:
	var bow: Vector2i = _slot_of(&"bow_vado")
	var bow_uid: int = _state.get_item(bow.x, bow.y).uid
	# Doble clic en el arco de la bolsa: a WEAPON_2, que está vacía.
	_view_of(bow)._gui_input(_click(MOUSE_BUTTON_LEFT, true))
	assert_eq(_sent.size(), 1)
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, bow.x, bow.y, 1, 1, 0, bow_uid], "equipar en WEAPON_2")
	# Clic derecho en el arco ya equipado (la vista optimista): a la primera libre de la bolsa.
	var free: int = _inventory.get_view().first_free(InventoryState.ContainerId.BAG)
	_character.get_slot_view(1)._gui_input(_click(MOUSE_BUTTON_RIGHT))
	assert_eq(_last_sent(), [InventoryOps.Op.MOVE, 1, 1, 0, free, 0, bow_uid], "desequipar a la bolsa")
	# La espada es el arma activa: desequiparla avisa y no sale.
	_character.get_slot_view(0)._gui_input(_click(MOUSE_BUTTON_RIGHT))
	assert_eq(_sent.size(), 2)
	assert_eq(_rejections.back()[0], InventoryOps.Result.WEAPON_REQUIRED)
	# Una poción no se equipa: nada.
	var potion: Vector2i = _slot_of(&"potion_health")
	assert_eq(_window.activate_item(potion), -1)
	assert_eq(_sent.size(), 2, "una poción no se equipa")
	# Un clic suelto no hace nada más que el de UIIconSlot.
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
	assert_true(_window.drop_outside(potion), "una poción se puede destruir")
	assert_true(_destroy.is_open(), "se pide confirmación")
	assert_true(_destroy.get_message_label().text.begins_with("¿Destruir Poción de vida ×%d?" % item.count),
			"«%s»" % _destroy.get_message_label().text)
	assert_true(_sent.is_empty(), "nada sale hasta confirmar")
	_destroy.confirm()
	assert_eq(_last_sent(), [InventoryOps.Op.DESTROY, potion.x, potion.y, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT,
			item.count, item.uid], "DESTROY de toda la pila con su uid")
	assert_null(_view_of(potion).get_item(), "optimista: la pila desaparece")
	# Cancelar no destruye.
	var stamina: Vector2i = _slot_of(&"potion_stamina")
	assert_true(_window.drop_outside(stamina))
	_destroy.cancel()
	assert_eq(_sent.size(), 1)
	# Lo que no se puede destruir no pregunta: el aviso y nada.
	var bow: Vector2i = _slot_of(&"bow_vado")
	assert_false(_window.drop_outside(bow), "el arco del Vado es indestructible")
	assert_false(_destroy.is_open())
	assert_eq(_rejections.back(), [InventoryOps.Result.LOCKED, "Ese objeto no se puede destruir"])
	assert_false(_window.drop_outside(Vector2i(1, 0)), "lo equipado tampoco")
	assert_eq(_sent.size(), 1)
	assert_eq(InventoryWindow.destroy_question(_state.get_item(bow.x, bow.y)), "¿Destruir Arco del Vado?",
			"sin cantidad en lo que no se apila")
	# Dentro de las ventanas no se destruye nada; fuera, sí.
	await wait_process_frames()
	_character.open()
	_window.open()
	await wait_process_frames()
	assert_true(_window.is_over_drop_zone(_window.get_global_rect().get_center()), "sobre el inventario")
	assert_true(_window.is_over_drop_zone(_character.get_global_rect().get_center()), "sobre el personaje")
	assert_false(_window.is_over_drop_zone(Vector2(-500.0, -500.0)), "fuera de las dos")
	assert_false(_window.get_global_rect().intersects(_character.get_global_rect()), "no se solapan")
	_character.close()
	assert_false(_window.is_over_drop_zone(_character.get_global_rect().get_center()), "una ventana cerrada no cuenta")
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
	assert_true(int(damage["heavy"]) > 0, "el arco tiene un disparo tensado con daño")
	assert_true(body.contains(InventorySlotView.TEXT_HEAVY % int(damage["heavy"])), "el daño del fuerte: %s" % body)
	assert_true(body.contains("Frente a Espada y escudo del Vado"), "la comparación con el arma de esa ranura")
	assert_true(body.contains(InventorySlotView.TEXT_BOUND), "ligado")
	assert_true(body.contains("Valor: 0 de oro"))
	assert_true(body.contains("Nivel requerido: 1"))
	assert_false(body.contains("[color=#%s]Nivel requerido" % UIPalette.DANGER.to_html(false)),
			"nivel 1 alcanzado: no va en rojo")
	# Con un arma que pide más nivel, la línea va en rojo.
	var strong: ItemDefinition = _db.get_definition(&"bow_vado").duplicate() as ItemDefinition
	strong.id = &"test_strong_bow"
	strong.required_level = 20
	var db: ItemDatabase = ItemDatabase.build_from_definitions([strong] as Array[ItemDefinition],
			CombatCatalog.tables())
	var strong_item: ItemInstance = ItemInstance.create(9, strong, 1)
	var red: String = InventorySlotView.tooltip_for(strong_item, db, 5)["body"]
	assert_true(red.contains("[color=#%s]Nivel requerido: 20[/color]" % UIPalette.DANGER.to_html(false)),
			"en rojo si no llega: %s" % red)
	# Una poción dice su efecto.
	var potion: Vector2i = _slot_of(&"potion_health")
	var potion_body: String = InventorySlotView.tooltip_for(_state.get_item(potion.x, potion.y), _db, 1)["body"]
	assert_true(potion_body.contains(CombatText.ability_description(CombatCatalog.ability_id(&"potion_health"))),
			"el efecto de la poción")
	# Una casilla de la bolsa con un arma compara con la ranura a la que iría con un doble clic.
	assert_true(String(_view_of(bow).get_tooltip_content()["body"]).contains("Frente a") == false,
			"con WEAPON_2 vacía no hay con qué comparar")
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
	assert_eq(locked.get_tooltip_content()["subtitle"], CharacterWindow.TEXT_SOON, "«Próximamente»")
	assert_false(locked.enabled, "en gris")
	assert_eq(_character.get_slot_view(0).get_item().def_id, &"sword_shield_vado", "la espada en WEAPON_1")
	assert_null(_character.get_slot_view(1).get_item(), "WEAPON_2 vacía")
	assert_eq(_character.get_slot_view(1).get_tooltip_content()["title"], "Arma 2")
	# Nivel, XP y puntos del progreso; la hoja de CombatRules.
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
	# La figura: con la apariencia (la de por defecto de Vardheim si los 8 B van a 0) y las armas.
	var zeros := PackedByteArray()
	zeros.resize(CharacterAppearance.ENCODED_SIZE)
	_character.set_identity("Ana", VARDHEIM, zeros)
	assert_eq(_character.get_name_label().text, "Ana")
	assert_null(_character.get_preview_visual(), "la figura no se monta hasta abrir")
	_character.open()
	var visual: HumanoidVisual = _character.get_preview_visual()
	if not assert_not_null(visual, "al abrir, la figura"):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var expected: CharacterAppearance = AppearanceApplier.resolve(zeros, VARDHEIM, catalog)
	assert_eq(visual.get_tint(&"skin"), catalog.skin_tones[expected.skin].color, "con la piel de su apariencia")
	assert_true(_character.get_preview_viewport().own_world_3d, "en su propio mundo")
	var bow_id: int = CombatCatalog.weapon_id(&"bow")
	_character.set_weapons(bow_id, 0)
	assert_eq(_character.get_preview_character().combat.weapon_id, bow_id, "con el arma activa")
	var yaw: float = _character.get_preview_yaw()
	_character.rotate_preview(100.0)
	assert_near(_character.get_preview_yaw(), yaw + 100.0 * CharacterWindow.TURN_RATE, 0.0001, "gira al arrastrar")
	await wait_process_frames(2)
	_character.close()
	assert_eq(_character.get_preview_viewport().render_target_update_mode, SubViewport.UPDATE_DISABLED,
			"cerrada no dibuja")
	_character.open()
	assert_eq(_character.get_preview_visual(), visual, "al volver a abrir, la misma figura")
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
	assert_null(hud.get_inventory_window(), "el sandbox no tiene inventario")
	hud.bind_net(client, null)
	var inventory_window: InventoryWindow = hud.get_inventory_window()
	var character_window: CharacterWindow = hud.get_character_window()
	if not assert_not_null(inventory_window, "en red, sí") or not assert_not_null(character_window):
		return
	assert_true(inventory_window.get_index() < hud.get_death_screen().get_index(), "por debajo de la muerte")
	assert_true(hud.get_split_dialog().get_index() > inventory_window.get_index(), "los diálogos encima")
	assert_eq(inventory_window.get_inventory(), client.get_inventory(), "con el inventario del cliente")
	# I y C abren las dos a la vez y liberan el cursor.
	tree.root.push_input(_key(KEY_I))
	assert_true(inventory_window.is_open(), "I abre el inventario")
	tree.root.push_input(_key(KEY_C))
	assert_true(character_window.is_open(), "C abre la de personaje")
	assert_true(inventory_window.is_open(), "las dos a la vez")
	assert_true(rig.is_ui_holding_cursor(), "con el cursor libre")
	tree.root.push_input(_key(KEY_I))
	assert_false(inventory_window.is_open(), "I la cierra")
	character_window.close()
	assert_false(rig.is_ui_holding_cursor())
	# Un gesto con el inventario del cliente sale por el cliente; un aviso, al chat.
	client.get_inventory().on_full_page(ProgressMessages.InventoryFull.split(1, _state)[0])
	var bow: Vector2i = _slot_of(&"bow_vado")
	assert_eq(inventory_window.activate_item(bow), InventoryOps.Result.OK)
	assert_eq(client.requests.size(), 1, "la petición sale por el cliente")
	var chat_lines: int = hud.get_chat().get_log().get_count()
	inventory_window.drop_outside(Vector2i(1, 0))
	assert_eq(hud.get_chat().get_log().get_count(), chat_lines + 1, "el aviso del rechazo, en el chat")
	# Con inventario, la pantalla de muerte no ofrece plantilla.
	hud._open_death_screen()
	assert_false(hud.get_death_screen().get_template_selector().visible, "sin selector de plantilla")
	hud.get_death_screen().close()
	# Con la pantalla de muerte abierta, I no abre nada.
	hud.get_death_screen().open("", 0, PackedStringArray())
	assert_false(hud.toggle_inventory_window(), "muerto no")
	hud.get_death_screen().close()
	# Una segunda llamada rehace las ventanas sin duplicarlas.
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
			"sin inventario (servidor sin progreso), la plantilla se sigue eligiendo")
	hud.get_death_screen().close()
	await wait_process_frames()
