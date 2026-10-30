class_name InventorySlotView
extends UIIconSlot
## Una casilla del inventario o del equipo (docs/progresion.md §11, UI-26): un [UIIconSlot] con arrastrar y
## soltar. Enseña el objeto de la vista de [ClientInventory] ([method show_item]): su icono (o, sin icono de
## ART-12, el nombre corto con el color de la categoría), la pila, el borde de su rareza y el tooltip de §11.2.
## Una pila provisional (la de un SPLIT que aún no tiene su [code]uid[/code] real) se ve apagada.
## [br][br]
## [b]Gestos.[/b] Arrastrar una casilla con objeto lleva [method make_drag_data] (con Mayúsculas, para dividir);
## soltar sobre otra casilla llama a [member drop_handler] con el origen, el destino y si se divide; un arrastre
## que nadie recoge emite [signal drag_cancelled] (soltar fuera de las ventanas: destruir). El doble clic y el
## clic derecho emiten [signal activated] (equipar o desequipar). La casilla no decide nada: eso es de
## [InventoryWindow]. Una casilla [member locked] (las ranuras de armadura de la fase 5) no se arrastra ni recibe.
## [br][br]
## Solo cliente.

## Doble clic o clic derecho sobre la casilla.
signal activated
## El arrastre que salió de esta casilla acabó sin que nadie lo recogiera.
signal drag_cancelled

## Clave del diccionario de arrastre con el origen [code](contenedor, ranura)[/code].
const DRAG_KEY: String = "inventory_slot"
## Tamaño de la vista previa que sigue al ratón.
const PREVIEW_SIZE: Vector2 = Vector2(44.0, 44.0)
## Color de cada categoría ([enum ItemDefinition.Category]) para el icono provisional. # TODO(arte): hasta los
## iconos de ART-12 y el visto bueno de las ventanas (docs/progresion.md §16).
const CATEGORY_COLORS: Dictionary[int, Color] = {
	ItemDefinition.Category.WEAPON: Color(0.56, 0.42, 0.26, 1.0),
	ItemDefinition.Category.ARMOR: Color(0.32, 0.42, 0.55, 1.0),
	ItemDefinition.Category.CONSUMABLE: Color(0.58, 0.2, 0.26, 1.0),
	ItemDefinition.Category.MATERIAL: Color(0.36, 0.5, 0.3, 1.0),
	ItemDefinition.Category.QUEST: Color(0.7, 0.58, 0.2, 1.0),
	ItemDefinition.Category.MISC: Color(0.42, 0.42, 0.46, 1.0),
}
## Nombre en español de cada categoría.
const CATEGORY_NAMES: Dictionary[int, String] = {
	ItemDefinition.Category.WEAPON: "Arma", ItemDefinition.Category.ARMOR: "Armadura",
	ItemDefinition.Category.CONSUMABLE: "Consumible", ItemDefinition.Category.MATERIAL: "Material",
	ItemDefinition.Category.QUEST: "Objeto de misión", ItemDefinition.Category.MISC: "Varios",
}
## Nombre en español de cada ranura de equipo ([enum ItemDefinition.EquipSlot]).
const EQUIP_SLOT_NAMES: Dictionary[int, String] = {
	ItemDefinition.EquipSlot.WEAPON: "Ranura de arma", ItemDefinition.EquipSlot.HEAD: "Cabeza",
	ItemDefinition.EquipSlot.CHEST: "Torso", ItemDefinition.EquipSlot.HANDS: "Manos",
	ItemDefinition.EquipSlot.LEGS: "Piernas", ItemDefinition.EquipSlot.FEET: "Pies",
}
const TEXT_REQUIRED_LEVEL: String = "Nivel requerido: %d"
const TEXT_BOUND: String = "Ligado"
const TEXT_VALUE: String = "Valor: %d de oro"
const TEXT_DURABILITY: String = "Durabilidad: %d %%"
const TEXT_LIGHT: String = "Ataques ligeros: %s"
const TEXT_HEAVY: String = "Ataque fuerte: %d"
const TEXT_ABILITY: String = "%s: %d de daño"
const TEXT_COMPARE: String = "Frente a %s: combo %s, fuerte %s"
const TEXT_PROVISIONAL: String = "Esperando al servidor…"

## Contenedor ([enum InventoryState.ContainerId]) y ranura que enseña.
var container: int = InventoryState.ContainerId.BAG
var slot: int = 0
## Reservada (equipo 2–6 en la fase 5): en gris, sin arrastre ni suelta.
var locked: bool = false:
	set(value):
		locked = value
		enabled = not value
## [code](from: Vector2i, to: Vector2i, split: bool) -> void[/code]: lo que pasa al soltar sobre esta casilla.
var drop_handler: Callable = Callable()
## Título del tooltip de la casilla vacía (en el equipo, el nombre de la ranura); vacío = sin tooltip.
var empty_title: String = ""
## Subtítulo del tooltip de la casilla vacía («Próximamente» en las reservadas).
var empty_subtitle: String = ""

var _item: ItemInstance = null
var _drag_source: bool = false


## La ranura que enseña: [code](contenedor, ranura)[/code].
func get_position_key() -> Vector2i:
	return Vector2i(container, slot)


## El objeto que enseña (null si está vacía).
func get_item() -> ItemInstance:
	return _item


## Enseña [param item] (null = vacía) con las definiciones de [param db] (null =
## [method ItemDatabase.shared]) para un personaje de nivel [param level]; [param compare] es el arma con la que
## se compara un arma en el tooltip (null = ninguna).
func show_item(item: ItemInstance, db: ItemDatabase = null, level: int = 1, compare: ItemInstance = null) -> void:
	_item = item
	if db == null:
		db = ItemDatabase.shared()
	var definition: ItemDefinition = db.get_definition(item.def_id) if item != null else null
	if item == null or definition == null:
		icon = null
		count = 0
		rarity = -1
		enabled = not locked
		if empty_title.is_empty():
			tooltip_info = {}
		else:
			set_tooltip_info(empty_title, "", empty_subtitle)
		return
	icon = icon_for(definition)
	count = item.count
	rarity = item.rarity
	enabled = not locked and not ClientInventory.is_provisional(item)
	var content: Dictionary = tooltip_for(item, db, level, compare)
	set_tooltip_info(content["title"], content["body"], content["subtitle"])


## Lo que lleva un arrastre desde esta casilla ([constant DRAG_KEY]: el origen, [code]uid[/code] y
## [code]split[/code]: con Mayúsculas se divide), o vacío si no hay nada que arrastrar (vacía, reservada o
## provisional).
func make_drag_data(split: bool) -> Dictionary:
	if locked or _item == null or ClientInventory.is_provisional(_item):
		return {}
	return {DRAG_KEY: get_position_key(), "uid": _item.uid, "split": split}


## true si se puede soltar [param data] aquí: un arrastre de otra casilla del inventario y esta no reservada.
func accepts(data: Variant) -> bool:
	if locked or not (data is Dictionary) or not (data as Dictionary).has(DRAG_KEY):
		return false
	return (data as Dictionary)[DRAG_KEY] != get_position_key()


## Suelta [param data] aquí: [member drop_handler] con el origen, esta casilla y si se divide.
func drop(data: Dictionary) -> void:
	if not accepts(data) or not drop_handler.is_valid():
		return
	drop_handler.call(data[DRAG_KEY] as Vector2i, get_position_key(), bool(data.get("split", false)))


# --- Presentación (estática: la usan las pruebas y la ventana de personaje) -----------------------

## El icono de [param definition]: el de [member ItemDefinition.icon_path] si existe y, si no, el nombre corto
## sobre el color de su categoría ([PlaceholderIcon]).
static func icon_for(definition: ItemDefinition) -> Texture2D:
	if definition == null:
		return null
	if not definition.icon_path.is_empty() and ResourceLoader.exists(definition.icon_path):
		var texture: Texture2D = load(definition.icon_path) as Texture2D
		if texture != null:
			return texture
	var placeholder := PlaceholderIcon.new()
	placeholder.letter = short_name(definition.display_name)
	placeholder.color = CATEGORY_COLORS.get(int(definition.category), CATEGORY_COLORS[ItemDefinition.Category.MISC])
	return placeholder


## El nombre corto del icono provisional: la inicial de la primera palabra y la de la última (si hay más de
## una), en mayúsculas («Poción de vida» → «PV», «Arco del Vado» → «AV»).
static func short_name(display_name: String) -> String:
	var words: PackedStringArray = display_name.strip_edges().split(" ", false)
	if words.is_empty():
		return "?"
	var text: String = words[0].left(1)
	if words.size() > 1:
		text += words[words.size() - 1].left(1)
	return text.to_upper()


## El tooltip de [param item] (§11.2): [code]title[/code] (el nombre), [code]subtitle[/code] (categoría y ranura)
## y [code]body[/code] en BBCode: nivel requerido (en rojo si [param level] no llega), lo que aporta (un arma, el
## daño de sus ataques y habilidades de [CombatCatalog]; una poción, su efecto), la comparación con
## [param compare] (verde si mejora, rojo si empeora), «Ligado», la durabilidad, el valor y la descripción.
static func tooltip_for(item: ItemInstance, db: ItemDatabase, level: int, compare: ItemInstance = null) -> Dictionary:
	if db == null:
		db = ItemDatabase.shared()
	var definition: ItemDefinition = db.get_definition(item.def_id) if item != null else null
	if definition == null:
		return {"title": "", "subtitle": "", "body": ""}
	var subtitle: String = CATEGORY_NAMES.get(int(definition.category), "")
	if definition.is_equipable():
		subtitle += " · %s" % EQUIP_SLOT_NAMES.get(int(definition.equip_slot), "")
	var lines: PackedStringArray = PackedStringArray()
	if ClientInventory.is_provisional(item):
		lines.append(_colored(TEXT_PROVISIONAL, UIPalette.TEXT_DIM))
	var level_line: String = TEXT_REQUIRED_LEVEL % definition.required_level
	lines.append(_colored(level_line, UIPalette.DANGER) if definition.required_level > level else level_line)
	match definition.category:
		ItemDefinition.Category.WEAPON:
			lines.append_array(_weapon_lines(definition, compare, db))
		ItemDefinition.Category.CONSUMABLE:
			var effect: String = CombatText.ability_description(CombatCatalog.ability_id(definition.ref_id))
			if not effect.is_empty():
				lines.append(effect)
	if item.bound:
		lines.append(_colored(TEXT_BOUND, UIPalette.TITLE))
	if definition.has_durability and item.durability >= 0:
		lines.append(TEXT_DURABILITY % roundi(item.durability / 10.0))
	lines.append(_colored(TEXT_VALUE % definition.base_value, UIPalette.TEXT_DIM))
	if not definition.description.is_empty():
		lines.append("[i]%s[/i]" % definition.description)
	return {"title": definition.display_name, "subtitle": subtitle, "body": "\n".join(lines)}


## El daño de un arma de [CombatCatalog] por su id: [code]lights[/code] (el de cada ligero del combo),
## [code]combo[/code] (su suma), [code]heavy[/code] (el fuerte sin cargar) y [code]abilities[/code]
## ([code][id de habilidad, daño][/code] de las que golpean).
static func weapon_damage(weapon_id: int) -> Dictionary:
	var result: Dictionary = {"lights": PackedInt32Array(), "combo": 0, "heavy": 0, "abilities": []}
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null:
		return result
	var lights := PackedInt32Array()
	var combo: int = 0
	for attack_id: int in weapon.light_ids:
		var attack: AttackTicks = CombatCatalog.attack(attack_id)
		if attack != null:
			lights.append(attack.base_damage)
			combo += attack.base_damage
	result["lights"] = lights
	result["combo"] = combo
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	result["heavy"] = heavy.base_damage if heavy != null else 0
	var abilities: Array = []
	for slot_index: int in range(CombatState.ABILITY_SLOTS):
		var ability: AbilityTicks = CombatCatalog.ability(weapon.ability_id(slot_index))
		if ability != null and ability.hit != null and ability.hit.base_damage > 0:
			abilities.append([ability.id, ability.hit.base_damage])
	result["abilities"] = abilities
	return result


static func _weapon_lines(definition: ItemDefinition, compare: ItemInstance, db: ItemDatabase) -> PackedStringArray:
	var lines := PackedStringArray()
	var damage: Dictionary = weapon_damage(CombatCatalog.weapon_id(definition.ref_id))
	var lights := PackedStringArray()
	for value: int in damage["lights"]:
		lights.append(str(value))
	if not lights.is_empty():
		lines.append(TEXT_LIGHT % " · ".join(lights))
	if int(damage["heavy"]) > 0:
		lines.append(TEXT_HEAVY % int(damage["heavy"]))
	for pair: Array in damage["abilities"]:
		lines.append(TEXT_ABILITY % [CombatText.ability_title(int(pair[0])), int(pair[1])])
	var other: ItemDefinition = db.get_definition(compare.def_id) if compare != null else null
	if other != null and other.category == ItemDefinition.Category.WEAPON and other.id != definition.id:
		var theirs: Dictionary = weapon_damage(CombatCatalog.weapon_id(other.ref_id))
		lines.append(TEXT_COMPARE % [other.display_name,
				_difference(int(damage["combo"]) - int(theirs["combo"])),
				_difference(int(damage["heavy"]) - int(theirs["heavy"]))])
	return lines


# «+30» en verde, «−20» en rojo o «=» en gris.
static func _difference(value: int) -> String:
	if value > 0:
		return _colored("+%d" % value, UIPalette.SUCCESS)
	if value < 0:
		return _colored("−%d" % -value, UIPalette.DANGER)
	return _colored("=", UIPalette.TEXT_DIM)


static func _colored(text: String, color: Color) -> String:
	return "[color=#%s]%s[/color]" % [color.to_html(false), text]


# --- Entrada ------------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click != null and click.pressed and (click.button_index == MOUSE_BUTTON_RIGHT
			or (click.button_index == MOUSE_BUTTON_LEFT and click.double_click)):
		activated.emit()
		accept_event()
		return
	super(event)


func _get_drag_data(_at_position: Vector2) -> Variant:
	var data: Dictionary = make_drag_data(Input.is_key_pressed(KEY_SHIFT))
	if data.is_empty():
		return null
	var preview := TextureRect.new()
	preview.texture = icon
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.custom_minimum_size = PREVIEW_SIZE
	preview.size = PREVIEW_SIZE
	preview.modulate.a = 0.85
	set_drag_preview(preview)
	_drag_source = true
	return data


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return accepts(data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is Dictionary:
		drop(data as Dictionary)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drag_source:
		_drag_source = false
		if is_inside_tree() and not get_viewport().gui_is_drag_successful():
			drag_cancelled.emit()
