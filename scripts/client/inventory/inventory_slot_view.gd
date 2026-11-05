class_name InventorySlotView
extends UIIconSlot
## An inventory or equipment slot (docs/progression.md §11, UI-26): a [UIIconSlot] with drag and
## drop. It shows the item from the [ClientInventory] view ([method show_item]): its icon (or, with no ART-12
## icon, the short name in the category color), the stack, the border of its rarity and the §11.2 tooltip.
## A provisional stack (that of a SPLIT that does not yet have its real [code]uid[/code]) is shown dimmed.
## [br][br]
## [b]Gestures.[/b] Dragging a slot with an item carries [method make_drag_data] (with Shift, to split);
## dropping onto another slot calls [member drop_handler] with the origin, the destination and whether it splits; a drag
## that nobody picks up emits [signal drag_cancelled] (drop outside the windows: destroy). Double click and
## right click emit [signal activated] (equip or unequip). The slot decides nothing: that is up to
## [InventoryWindow]. A [member locked] slot (the armor slots of phase 5) cannot be dragged or receive.
## [br][br]
## Client only.

## Double click or right click on the slot.
signal activated
## The drag that started from this slot ended without anyone picking it up.
signal drag_cancelled

## Key of the drag dictionary with the origin [code](container, slot)[/code].
const DRAG_KEY: String = "inventory_slot"
## Size of the preview that follows the mouse.
const PREVIEW_SIZE: Vector2 = Vector2(44.0, 44.0)
## Color of each category ([enum ItemDefinition.Category]) for the provisional icon. # TODO(art): until the
## ART-12 icons and the approval of the windows (docs/progression.md §16).
const CATEGORY_COLORS: Dictionary[int, Color] = {
	ItemDefinition.Category.WEAPON: Color(0.56, 0.42, 0.26, 1.0),
	ItemDefinition.Category.ARMOR: Color(0.32, 0.42, 0.55, 1.0),
	ItemDefinition.Category.CONSUMABLE: Color(0.58, 0.2, 0.26, 1.0),
	ItemDefinition.Category.MATERIAL: Color(0.36, 0.5, 0.3, 1.0),
	ItemDefinition.Category.QUEST: Color(0.7, 0.58, 0.2, 1.0),
	ItemDefinition.Category.MISC: Color(0.42, 0.42, 0.46, 1.0),
}
## Name in Spanish of each category.
const CATEGORY_NAMES: Dictionary[int, String] = {
	ItemDefinition.Category.WEAPON: "Arma", ItemDefinition.Category.ARMOR: "Armadura",
	ItemDefinition.Category.CONSUMABLE: "Consumible", ItemDefinition.Category.MATERIAL: "Material",
	ItemDefinition.Category.QUEST: "Objeto de misión", ItemDefinition.Category.MISC: "Varios",
}
## Name in Spanish of each equipment slot ([enum ItemDefinition.EquipSlot]).
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

## Container ([enum InventoryState.ContainerId]) and slot it shows.
var container: int = InventoryState.ContainerId.BAG
var slot: int = 0
## Reserved (equipment 2-6 in phase 5): grayed out, no drag or drop.
var locked: bool = false:
	set(value):
		locked = value
		enabled = not value
## [code](from: Vector2i, to: Vector2i, split: bool) -> void[/code]: what happens when dropping onto this slot.
var drop_handler: Callable = Callable()
## Title of the empty slot's tooltip (in the equipment, the slot's name); empty = no tooltip.
var empty_title: String = ""
## Subtitle of the empty slot's tooltip ("Próximamente" (coming soon) on the reserved ones).
var empty_subtitle: String = ""

var _item: ItemInstance = null
var _drag_source: bool = false


## The slot it shows: [code](container, slot)[/code].
func get_position_key() -> Vector2i:
	return Vector2i(container, slot)


## The item it shows (null if empty).
func get_item() -> ItemInstance:
	return _item


## Shows [param item] (null = empty) with the definitions of [param db] (null =
## [method ItemDatabase.shared]) for a character of level [param level]; [param compare] is the weapon a weapon is
## compared against in the tooltip (null = none).
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


## What a drag from this slot carries ([constant DRAG_KEY]: the origin, [code]uid[/code] and
## [code]split[/code]: with Shift it splits), or empty if there is nothing to drag (empty, reserved or
## provisional).
func make_drag_data(split: bool) -> Dictionary:
	if locked or _item == null or ClientInventory.is_provisional(_item):
		return {}
	return {DRAG_KEY: get_position_key(), "uid": _item.uid, "split": split}


## true if [param data] can be dropped here: a drag from another inventory slot and this one not reserved.
func accepts(data: Variant) -> bool:
	if locked or not (data is Dictionary) or not (data as Dictionary).has(DRAG_KEY):
		return false
	return (data as Dictionary)[DRAG_KEY] != get_position_key()


## Drops [param data] here: [member drop_handler] with the origin, this slot and whether it splits.
func drop(data: Dictionary) -> void:
	if not accepts(data) or not drop_handler.is_valid():
		return
	drop_handler.call(data[DRAG_KEY] as Vector2i, get_position_key(), bool(data.get("split", false)))


# --- Presentation (static: used by the tests and the character window) ---------------------------

## The icon of [param definition]: that of [member ItemDefinition.icon_path] if it exists and, if not, the short name
## on the color of its category ([PlaceholderIcon]).
static func icon_for(definition: ItemDefinition) -> Texture2D:
	if definition == null:
		return null
	if not definition.icon_path.is_empty() and ResourceLoader.exists(definition.icon_path):
		var texture: Texture2D = load(definition.icon_path) as Texture2D
		if texture != null:
			return texture
	# ART-12: weapons and potions carry the drawing from the action bar (by the combat resource's name).
	var drawn: Texture2D = null
	match definition.category:
		ItemDefinition.Category.WEAPON:
			drawn = CombatIcons.named(StringName("weapon_%s" % definition.ref_id))
		ItemDefinition.Category.CONSUMABLE:
			drawn = CombatIcons.named(definition.ref_id)
	if drawn != null:
		return drawn
	var placeholder := PlaceholderIcon.new()
	placeholder.letter = short_name(definition.display_name)
	placeholder.color = CATEGORY_COLORS.get(int(definition.category), CATEGORY_COLORS[ItemDefinition.Category.MISC])
	return placeholder


## The short name of the provisional icon: the initial of the first word and that of the last (if there is more than
## one), in uppercase ("Poción de vida" -> "PV", "Arco del Vado" -> "AV").
static func short_name(display_name: String) -> String:
	var words: PackedStringArray = display_name.strip_edges().split(" ", false)
	if words.is_empty():
		return "?"
	var text: String = words[0].left(1)
	if words.size() > 1:
		text += words[words.size() - 1].left(1)
	return text.to_upper()


## The tooltip of [param item] (§11.2): [code]title[/code] (the name), [code]subtitle[/code] (category and slot)
## and [code]body[/code] in BBCode: required level (in red if [param level] falls short), what it provides (a weapon, the
## damage of its attacks and abilities from [CombatCatalog]; a potion, its effect), the comparison with
## [param compare] (green if better, red if worse), "Ligado" (bound), durability, value and description.
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


## The damage of a [CombatCatalog] weapon by its id: [code]lights[/code] (that of each light attack of the combo),
## [code]combo[/code] (their sum), [code]heavy[/code] (the uncharged heavy) and [code]abilities[/code]
## ([code][ability id, damage][/code] of those that hit).
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


# "+30" in green, "−20" in red or "=" in gray.
static func _difference(value: int) -> String:
	if value > 0:
		return _colored("+%d" % value, UIPalette.SUCCESS)
	if value < 0:
		return _colored("−%d" % -value, UIPalette.DANGER)
	return _colored("=", UIPalette.TEXT_DIM)


static func _colored(text: String, color: Color) -> String:
	return "[color=#%s]%s[/color]" % [color.to_html(false), text]


# --- Input --------------------------------------------------------------------------------------

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
