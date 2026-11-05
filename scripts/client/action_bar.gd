class_name ActionBar
extends Control
## Action bar (UI-11, docs/abilities.md, section 6.3): bottom center, above health and
## stamina. Slots ([UIIconSlot]) for the light and heavy attack (with the bow, the quick shot and the
## draw), the block (hidden if the weapon cannot block), the dodge, abilities 1-3 of the active weapon,
## the two potions with their charges and the weapon swap with the icon of the weapon in the other slot.
## [br][br]
## [b]It reads the predicted state every frame[/b] ([member PlayerCharacter.combat] at tick
## [member PlayerCharacter.last_input_tick], the last predicted one): the cooldown of each slot is
## [code]ability_ready[i] - tick[/code] (or the shared one of the potions), with a sweep and seconds, and
## a flash when it becomes ready. It predicts nothing on its own: a server rejection (reconciliation
## removes the ability and returns [code]ability_ready[/code] to its value) leaves the slot ready on the
## next frame, with no flash. [method ActionMachine.ability_status] dims the slots that cannot be used
## right now (BLOCKED) and crosses out potions without charges (NO_CHARGES); the dodge and the block are
## dimmed when exhausted, and the dodge blinks when an action fails for lack of stamina
## ([method notify_no_stamina], bit 1 of [member CombatState.combat_flags], like the stamina bar).
## The icons change when the weapon changes.
## [br][br]
## [b]Pressing during a cooldown[/b] (or a potion without charges) makes the slot blink: the client sees
## it in the inputs its controller generates ([signal LocalPlayerController.input_generated],
## [method handle_input]); it is not sent over the network.
## [br][br]
## Placeholder icons until ART-12: squares with the weapon's initial and color ([CombatIcons]). Client
## only.

## Slots, in the order they are shown.
enum Slot { PRIMARY, BLOCK, DODGE, ABILITY_1, ABILITY_2, ABILITY_3, CONSUMABLE_1, CONSUMABLE_2, SWAP }

## [InputMap] action of each slot (the glyph of its key).
const SLOT_ACTIONS: Array[StringName] = [
	&"primary_attack", &"block", &"dodge", &"ability_1", &"ability_2", &"ability_3",
	&"consumable_1", &"consumable_2", &"swap_weapon",
]
## Gap (px) between slots and between groups (attacks, abilities, potions, swap).
const SLOT_GAP: int = 6
const GROUP_GAP: float = 16.0
## Translucent band behind the slots: margin (px) around them and color.
const BACKDROP_PADDING: Vector2 = Vector2(10.0, 6.0)
const BACKDROP_COLOR: Color = Color(0.03, 0.035, 0.045, 0.58)
## Seconds a slot blinks when pressed at the wrong time.
const BLINK_SECONDS: float = 0.45
const BLINK_HERTZ: float = 8.0
const BLINK_COLOR: Color = Color(1.0, 0.2, 0.15, 1.0)
const CROSS_COLOR: Color = Color(0.9, 0.15, 0.12, 0.9)
## Letter of the slots that are not abilities.
const ICON_ATTACK: StringName = &"sword_light"
const ICON_SHOT: StringName = &"bow_quick"
const ICON_BLOCK: StringName = &"block"
const ICON_DODGE: StringName = &"dodge"
## Fallback letters (if an icon's drawing is missing).
const LETTER_ATTACK: String = "A"
const LETTER_SHOT: String = "D"
const LETTER_BLOCK: String = "B"
const LETTER_DODGE: String = "E"

## [PlayerInput] buttons of the slots with a cooldown, and the [method ActionMachine.ability_status]
## slot that corresponds to them.
const _COOLDOWN_BUTTONS: Dictionary[int, Vector2i] = {
	PlayerInput.ABILITY_1: Vector2i(Slot.ABILITY_1, 0),
	PlayerInput.ABILITY_2: Vector2i(Slot.ABILITY_2, 1),
	PlayerInput.ABILITY_3: Vector2i(Slot.ABILITY_3, 2),
	PlayerInput.CONSUMABLE_1: Vector2i(Slot.CONSUMABLE_1, ActionMachine.STATUS_SLOT_CONSUMABLE_1),
	PlayerInput.CONSUMABLE_2: Vector2i(Slot.CONSUMABLE_2, ActionMachine.STATUS_SLOT_CONSUMABLE_2),
}


## A slot of the bar: a [UIIconSlot] that also gets crossed out (potion without charges), blinks red
## (pressed at the wrong time, or the dodge without stamina) and shows the charges even when one is left. It does
## not take keyboard focus: the bar must not hold on to Enter or the space bar.
class ActionSlot extends UIIconSlot:
	## Crossed out: there are no charges.
	var crossed: bool = false:
		set(value):
			if crossed != value:
				crossed = value
				queue_redraw()
	## Shows [member UIIconSlot.count] even when it is 1 (a potion's charges).
	var always_show_count: bool = false
	var _blink_left: float = 0.0
	var _blink_clock: float = 0.0
	var _blinks: int = 0

	func _init() -> void:
		super()
		focus_mode = Control.FOCUS_NONE
		mouse_filter = Control.MOUSE_FILTER_PASS

	## Blinks red for [constant BLINK_SECONDS] s.
	func blink() -> void:
		_blink_left = BLINK_SECONDS
		_blink_clock = 0.0
		_blinks += 1
		queue_redraw()

	func is_blinking() -> bool:
		return _blink_left > 0.0

	## Number of times it has blinked since it was created.
	func get_blink_count() -> int:
		return _blinks

	## Advances the blink by [param delta] seconds.
	func advance_blink(delta: float) -> void:
		if _blink_left <= 0.0:
			return
		_blink_left = maxf(_blink_left - delta, 0.0)
		_blink_clock += delta
		queue_redraw()

	func get_count_text() -> String:
		if always_show_count:
			return str(count) if count > 0 else ""
		return super()

	func _draw() -> void:
		super()
		var rect := Rect2(Vector2.ZERO, size)
		if crossed:
			draw_line(rect.position + Vector2(6.0, 6.0), rect.end - Vector2(6.0, 6.0), CROSS_COLOR, 3.0, true)
			draw_line(Vector2(rect.end.x - 6.0, 6.0), Vector2(6.0, rect.end.y - 6.0), CROSS_COLOR, 3.0, true)
		if _blink_left > 0.0 and int(_blink_clock * BLINK_HERTZ * 2.0) % 2 == 0:
			draw_rect(rect.grow(-1.0), BLINK_COLOR, false, 3.0)


var _character: PlayerCharacter = null
var _controller: LocalPlayerController = null
var _row: HBoxContainer = null
var _slots: Array[ActionSlot] = []
# Last "ready" tick seen in each slot (-1 = none): if it does not change and is reached, the
# cooldown ended on its own (flash); if it changes to a lower value, it was a rejection or a weapon swap (no flash).
var _last_ready: PackedInt64Array = PackedInt64Array()
var _shown_weapon: int = -1
var _shown_alt_weapon: int = -1
var _previous_buttons: int = 0


func _init() -> void:
	name = "ActionBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _process(delta: float) -> void:
	if is_instance_valid(_character):
		refresh(_character.combat, _character.last_input_tick, delta)


func _exit_tree() -> void:
	_disconnect_controller()


# The dark band behind the slots (UI-55): the bottom block reads as a single piece with the health bar.
func _draw() -> void:
	if _row == null:
		return
	var width: float = _row.get_combined_minimum_size().x
	var band := Rect2((size.x - width) * 0.5, 0.0, width, size.y).grow_individual(
			BACKDROP_PADDING.x, BACKDROP_PADDING.y, BACKDROP_PADDING.x, BACKDROP_PADDING.y)
	var box := StyleBoxFlat.new()
	box.bg_color = BACKDROP_COLOR
	box.border_color = UIPalette.BORDER_DIM
	box.set_border_width_all(1)
	box.border_width_top = 2
	box.set_corner_radius_all(6)
	box.anti_aliasing = true
	draw_style_box(box, band)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## Connects the bar to the local character (its predicted state) and, if given, to its controller (so
## that a press at the wrong time makes the slot blink). With null the bar stays still.
func bind(character: PlayerCharacter, controller: LocalPlayerController = null) -> void:
	_character = character
	_disconnect_controller()
	_controller = controller
	if is_instance_valid(_controller):
		_controller.input_generated.connect(handle_input)
	_shown_weapon = -1
	_shown_alt_weapon = -1
	_last_ready.fill(-1)
	_previous_buttons = 0


## The [param kind] slot ([enum Slot]).
func get_slot(kind: int) -> ActionSlot:
	return _slots[kind] if kind >= 0 and kind < _slots.size() else null


## Weapon whose icons are shown now (-1 before the first [method refresh]).
func get_shown_weapon() -> int:
	return _shown_weapon


## Brings the bar up to date with the state [param state] at tick [param tick] (the predicted one) and advances
## the blinks by [param delta] seconds. [method _process] calls it every frame with the character from
## [method bind]; the tests, with exact states and ticks.
func refresh(state: CombatState, tick: int, delta: float = 0.0) -> void:
	if state == null:
		return
	if state.weapon_id != _shown_weapon or state.alt_weapon_id != _shown_alt_weapon:
		_show_weapons(state)
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	var exhausted: bool = state.is_exhausted()
	var data: CombatTables = CombatCatalog.tables()
	var no_cooldowns: bool = (state.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS) != 0
	# Abilities of the active weapon.
	for index: int in CombatState.ABILITY_SLOTS:
		var slot: ActionSlot = _slots[Slot.ABILITY_1 + index]
		var status: int = ActionMachine.ability_status(state, index, tick)
		var ability: AbilityTicks = data.ability(weapon.ability_id(index)) \
				if weapon != null and weapon.ability_id(index) != 0 else null
		var total: int = ability.cooldown_ticks if ability != null else 0
		_apply_cooldown(Slot.ABILITY_1 + index, state.ability_ready[index], total, tick, no_cooldowns)
		_set_flags(slot, status == ActionMachine.AbilityStatus.READY
				or status == ActionMachine.AbilityStatus.COOLDOWN,
				state.action == CombatState.Action.ABILITY and ability != null and state.action_id == ability.id)
	# Potions (shared cooldown and charges).
	for index: int in CombatState.CONSUMABLE_SLOTS:
		var kind: int = Slot.CONSUMABLE_1 + index
		var slot: ActionSlot = _slots[kind]
		var status: int = ActionMachine.ability_status(state,
				ActionMachine.STATUS_SLOT_CONSUMABLE_1 + index, tick)
		var has_potion: bool = status != ActionMachine.AbilityStatus.EMPTY
		var charges: int = state.charges_of(index) if has_potion else 0
		if slot.count != charges:
			slot.count = charges
		slot.crossed = status == ActionMachine.AbilityStatus.NO_CHARGES
		_apply_cooldown(kind, state.consumable_ready_tick if has_potion else 0,
				data.consumable_cooldown_ticks, tick, no_cooldowns)
		_set_flags(slot, status == ActionMachine.AbilityStatus.READY
				or status == ActionMachine.AbilityStatus.COOLDOWN,
				state.action == CombatState.Action.ABILITY and has_potion
				and state.action_id == data.consumable_ids[index])
	# Attack, block, dodge and weapon swap.
	var can_block: bool = weapon == null or weapon.can_block
	if _slots[Slot.BLOCK].visible != can_block:
		_slots[Slot.BLOCK].visible = can_block
		queue_redraw()
	_set_flags(_slots[Slot.BLOCK], not exhausted, false)
	_set_flags(_slots[Slot.DODGE], not exhausted, false)
	_set_flags(_slots[Slot.SWAP], state.alt_weapon_id != 0, state.action == CombatState.Action.SWAP)
	for slot: ActionSlot in _slots:
		slot.advance_blink(delta)


## The input [param input] the controller has just generated: presses (edges) of an ability on cooldown
## or of a potion without charges or on cooldown make its slot blink. Replaced inputs do not count.
func handle_input(input: PlayerInput) -> void:
	if input == null:
		return
	var pressed: int = input.buttons & ~_previous_buttons
	_previous_buttons = input.buttons
	if (input.buttons & PlayerInput.SUBSTITUTED) != 0 or not is_instance_valid(_character):
		return
	for button: int in _COOLDOWN_BUTTONS:
		if (pressed & button) == 0:
			continue
		var target: Vector2i = _COOLDOWN_BUTTONS[button]
		var status: int = ActionMachine.ability_status(_character.combat, target.y, input.tick)
		if status == ActionMachine.AbilityStatus.COOLDOWN \
				or status == ActionMachine.AbilityStatus.NO_CHARGES:
			_slots[target.x].blink()


## An action has failed for lack of stamina: the dodge blinks (like the stamina bar).
func notify_no_stamina() -> void:
	_slots[Slot.DODGE].blink()


# --- Internal ---------------------------------------------------------------------------------

func _build() -> void:
	_row = HBoxContainer.new()
	_row.name = "Casillas"
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override(&"separation", SLOT_GAP)
	add_child(_row)
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_last_ready.resize(Slot.size())
	_last_ready.fill(-1)
	for kind: int in Slot.size():
		if kind == Slot.ABILITY_1 or kind == Slot.CONSUMABLE_1 or kind == Slot.SWAP:
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(GROUP_GAP, 0.0)
			spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_row.add_child(spacer)
		var slot := ActionSlot.new()
		slot.name = String(Slot.keys()[kind]).capitalize().replace(" ", "")
		slot.key_action = SLOT_ACTIONS[kind]
		slot.always_show_count = kind == Slot.CONSUMABLE_1 or kind == Slot.CONSUMABLE_2
		_row.add_child(slot)
		_slots.append(slot)


func _disconnect_controller() -> void:
	if is_instance_valid(_controller) and _controller.input_generated.is_connected(handle_input):
		_controller.input_generated.disconnect(handle_input)


# Icons and tooltips of the active weapon, its abilities, the potions and the weapon in the other slot.
func _show_weapons(state: CombatState) -> void:
	_shown_weapon = state.weapon_id
	_shown_alt_weapon = state.alt_weapon_id
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	var ranged: bool = is_ranged(weapon)
	var primary: ActionSlot = _slots[Slot.PRIMARY]
	primary.icon = CombatIcons.named_or_letter(ICON_SHOT if ranged else ICON_ATTACK,
			LETTER_SHOT if ranged else LETTER_ATTACK, CombatIcons.weapon_color(state.weapon_id))
	_set_tooltip(primary, CombatText.TEXT_QUICK_SHOT if ranged else CombatText.TEXT_LIGHT,
			CombatText.TEXT_DRAWN_SHOT if ranged else CombatText.TEXT_HEAVY)
	var block: ActionSlot = _slots[Slot.BLOCK]
	block.icon = CombatIcons.named_or_letter(ICON_BLOCK, LETTER_BLOCK, CombatIcons.weapon_color(state.weapon_id))
	_set_tooltip(block, CombatText.TEXT_BLOCK)
	var dodge: ActionSlot = _slots[Slot.DODGE]
	dodge.icon = CombatIcons.named_or_letter(ICON_DODGE, LETTER_DODGE, CombatIcons.NEUTRAL_COLOR)
	_set_tooltip(dodge, CombatText.TEXT_DODGE)
	for index: int in CombatState.ABILITY_SLOTS:
		var slot: ActionSlot = _slots[Slot.ABILITY_1 + index]
		var ability_id: int = weapon.ability_id(index) if weapon != null else 0
		slot.icon = CombatIcons.ability_icon(ability_id) if ability_id != 0 else null
		if ability_id != 0:
			_set_tooltip(slot, CombatText.ability_title(ability_id), CombatText.ability_description(ability_id))
		else:
			_set_tooltip(slot, CombatText.TEXT_EMPTY_SLOT)
	var consumables: PackedInt32Array = CombatCatalog.consumable_ids()
	for index: int in CombatState.CONSUMABLE_SLOTS:
		var slot: ActionSlot = _slots[Slot.CONSUMABLE_1 + index]
		var potion: int = consumables[index] if index < consumables.size() else 0
		slot.icon = CombatIcons.ability_icon(potion) if potion != 0 else null
		_set_tooltip(slot, CombatText.ability_title(potion), CombatText.ability_description(potion))
	var swap: ActionSlot = _slots[Slot.SWAP]
	if state.alt_weapon_id != 0:
		swap.icon = CombatIcons.weapon_icon(state.alt_weapon_id)
		_set_tooltip(swap, CombatText.TEXT_SWAP_TO % CombatText.weapon_title(state.alt_weapon_id))
	else:
		swap.icon = null
		_set_tooltip(swap, CombatText.TEXT_SWAP, CombatText.TEXT_NO_SECOND_WEAPON)
	# The cooldowns belong to another weapon: none ends "on its own" on this swap.
	for kind: int in [Slot.ABILITY_1, Slot.ABILITY_2, Slot.ABILITY_3]:
		_last_ready[kind] = -1


## true if [param weapon] shoots (its heavy attack carries a projectile): the bow.
static func is_ranged(weapon: WeaponTicks) -> bool:
	if weapon == null:
		return false
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	return heavy != null and heavy.projectile_id != 0


# Changes [member UIIconSlot.enabled] and [member UIIconSlot.selected] only if they change (every assignment redraws
# the slot, and the bar is brought up to date every frame).
static func _set_flags(slot: ActionSlot, enabled: bool, selected: bool) -> void:
	if slot.enabled != enabled:
		slot.enabled = enabled
	if slot.selected != selected:
		slot.selected = selected


static func _set_tooltip(slot: ActionSlot, title: String, body: String = "") -> void:
	slot.set_tooltip_info(title, body)
	slot.tooltip_text = title if body.is_empty() else "%s\n%s" % [title, body]


# Cooldown of slot [param kind]: ready at [param ready_tick], out of [param total_ticks].
func _apply_cooldown(kind: int, ready_tick: int, total_ticks: int, tick: int, no_cooldowns: bool) -> void:
	var slot: ActionSlot = _slots[kind]
	var previous_ready: int = _last_ready[kind]
	_last_ready[kind] = ready_tick
	var remaining: int = 0 if no_cooldowns else ready_tick - tick
	var rate: float = float(Engine.physics_ticks_per_second)
	if remaining > 0:
		slot.set_cooldown(float(remaining) / rate, float(maxi(total_ticks, remaining)) / rate)
	elif slot.is_on_cooldown():
		if ready_tick == previous_ready and not no_cooldowns:
			# Ended on its own: the sweep finishes with its flash.
			slot.advance(slot.get_cooldown_remaining())
		else:
			# A rejection (reconciliation removed the ability) or a weapon swap: ready with no flash.
			slot.clear_cooldown()
