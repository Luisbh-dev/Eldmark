class_name ActionBar
extends Control
## Barra de acciones (UI-11, docs/habilidades.md, sección 6.3): abajo al centro, sobre la vida y la
## resistencia. Casillas ([UIIconSlot]) para el ataque ligero y fuerte (con el arco, el disparo rápido y el
## tensado), el bloqueo (oculto si el arma no bloquea), la esquiva, las habilidades 1–3 del arma activa,
## las dos pociones con sus cargas y el cambio de arma con el icono del arma de la otra ranura.
## [br][br]
## [b]Lee el estado predicho cada fotograma[/b] ([member PlayerCharacter.combat] en el tick
## [member PlayerCharacter.last_input_tick], el último predicho): la reutilización de cada casilla es
## [code]ability_ready[i] − tick[/code] (o la compartida de las pociones), con barrido y segundos, y
## destello al quedar lista. No predice nada por su cuenta: un rechazo del servidor (la reconciliación
## quita la habilidad y devuelve [code]ability_ready[/code] a su valor) deja la casilla lista en el
## fotograma siguiente, sin destello. [method ActionMachine.ability_status] apaga las casillas que ahora
## no se pueden usar (BLOCKED) y tacha las pociones sin cargas (NO_CHARGES); la esquiva y el bloqueo se
## apagan agotado y la esquiva parpadea cuando una acción falla por falta de resistencia
## ([method notify_no_stamina], el bit 1 de [member CombatState.combat_flags], como la barra de
## resistencia). Al cambiar de arma cambian los iconos.
## [br][br]
## [b]Pulsar en reutilización[/b] (o una poción sin cargas) hace parpadear la casilla: lo ve el cliente
## en las entradas que genera su controlador ([signal LocalPlayerController.input_generated],
## [method handle_input]); no viaja.
## [br][br]
## Iconos provisionales hasta ART-12: cuadros con la inicial y el color del arma ([CombatIcons]). Solo
## cliente.

## Casillas, en el orden en que se ven.
enum Slot { PRIMARY, BLOCK, DODGE, ABILITY_1, ABILITY_2, ABILITY_3, CONSUMABLE_1, CONSUMABLE_2, SWAP }

## Acción del [InputMap] de cada casilla (el glifo de su tecla).
const SLOT_ACTIONS: Array[StringName] = [
	&"primary_attack", &"block", &"dodge", &"ability_1", &"ability_2", &"ability_3",
	&"consumable_1", &"consumable_2", &"swap_weapon",
]
## Separación (px) entre casillas y entre grupos (ataques, habilidades, pociones, cambio).
const SLOT_GAP: int = 6
const GROUP_GAP: float = 16.0
## Banda translúcida detrás de las casillas: margen (px) alrededor y color.
const BACKDROP_PADDING: Vector2 = Vector2(10.0, 6.0)
const BACKDROP_COLOR: Color = Color(0.03, 0.035, 0.045, 0.58)
## Segundos que parpadea una casilla pulsada a destiempo.
const BLINK_SECONDS: float = 0.45
const BLINK_HERTZ: float = 8.0
const BLINK_COLOR: Color = Color(1.0, 0.2, 0.15, 1.0)
const CROSS_COLOR: Color = Color(0.9, 0.15, 0.12, 0.9)
## Letra de las casillas que no son habilidades.
const ICON_ATTACK: StringName = &"sword_light"
const ICON_SHOT: StringName = &"bow_quick"
const ICON_BLOCK: StringName = &"block"
const ICON_DODGE: StringName = &"dodge"
## Letras de reserva (si falta el dibujo de un icono).
const LETTER_ATTACK: String = "A"
const LETTER_SHOT: String = "D"
const LETTER_BLOCK: String = "B"
const LETTER_DODGE: String = "E"

## Botones de [PlayerInput] de las casillas con reutilización, y la casilla de
## [method ActionMachine.ability_status] que les toca.
const _COOLDOWN_BUTTONS: Dictionary[int, Vector2i] = {
	PlayerInput.ABILITY_1: Vector2i(Slot.ABILITY_1, 0),
	PlayerInput.ABILITY_2: Vector2i(Slot.ABILITY_2, 1),
	PlayerInput.ABILITY_3: Vector2i(Slot.ABILITY_3, 2),
	PlayerInput.CONSUMABLE_1: Vector2i(Slot.CONSUMABLE_1, ActionMachine.STATUS_SLOT_CONSUMABLE_1),
	PlayerInput.CONSUMABLE_2: Vector2i(Slot.CONSUMABLE_2, ActionMachine.STATUS_SLOT_CONSUMABLE_2),
}


## Una casilla de la barra: un [UIIconSlot] que además se tacha (poción sin cargas), parpadea en rojo
## (pulsada a destiempo, o la esquiva sin resistencia) y enseña las cargas aunque quede una. No toma el
## foco del teclado: la barra no debe quedarse con Intro ni con la barra espaciadora.
class ActionSlot extends UIIconSlot:
	## Tachada: no hay cargas.
	var crossed: bool = false:
		set(value):
			if crossed != value:
				crossed = value
				queue_redraw()
	## Enseña [member UIIconSlot.count] también cuando es 1 (las cargas de una poción).
	var always_show_count: bool = false
	var _blink_left: float = 0.0
	var _blink_clock: float = 0.0
	var _blinks: int = 0

	func _init() -> void:
		super()
		focus_mode = Control.FOCUS_NONE
		mouse_filter = Control.MOUSE_FILTER_PASS

	## Parpadea en rojo [constant BLINK_SECONDS] s.
	func blink() -> void:
		_blink_left = BLINK_SECONDS
		_blink_clock = 0.0
		_blinks += 1
		queue_redraw()

	func is_blinking() -> bool:
		return _blink_left > 0.0

	## Veces que ha parpadeado desde que existe.
	func get_blink_count() -> int:
		return _blinks

	## Avanza el parpadeo [param delta] segundos.
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
# Último tick de «lista» visto en cada casilla (-1 = ninguno): si no cambia y se alcanza, la
# reutilización acabó sola (destello); si cambia a menos, fue un rechazo o un cambio de arma (sin él).
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


# La banda oscura detrás de las casillas (UI-55): el bloque inferior se lee como una sola pieza con la vida.
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


## Conecta la barra con el personaje local (su estado predicho) y, si se da, con su controlador (para
## que una pulsación a destiempo haga parpadear la casilla). Con null la barra se queda quieta.
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


## La casilla [param kind] ([enum Slot]).
func get_slot(kind: int) -> ActionSlot:
	return _slots[kind] if kind >= 0 and kind < _slots.size() else null


## Arma cuyos iconos se enseñan ahora (-1 antes del primer [method refresh]).
func get_shown_weapon() -> int:
	return _shown_weapon


## Pone la barra al día con el estado [param state] en el tick [param tick] (el predicho) y avanza
## [param delta] segundos los parpadeos. [method _process] lo llama cada fotograma con el personaje de
## [method bind]; las pruebas, con estados y ticks exactos.
func refresh(state: CombatState, tick: int, delta: float = 0.0) -> void:
	if state == null:
		return
	if state.weapon_id != _shown_weapon or state.alt_weapon_id != _shown_alt_weapon:
		_show_weapons(state)
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	var exhausted: bool = state.is_exhausted()
	var data: CombatTables = CombatCatalog.tables()
	var no_cooldowns: bool = (state.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS) != 0
	# Habilidades del arma activa.
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
	# Pociones (reutilización compartida y cargas).
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
	# Ataque, bloqueo, esquiva y cambio de arma.
	var can_block: bool = weapon == null or weapon.can_block
	if _slots[Slot.BLOCK].visible != can_block:
		_slots[Slot.BLOCK].visible = can_block
		queue_redraw()
	_set_flags(_slots[Slot.BLOCK], not exhausted, false)
	_set_flags(_slots[Slot.DODGE], not exhausted, false)
	_set_flags(_slots[Slot.SWAP], state.alt_weapon_id != 0, state.action == CombatState.Action.SWAP)
	for slot: ActionSlot in _slots:
		slot.advance_blink(delta)


## La entrada [param input] que acaba de generar el controlador: las pulsaciones (flancos) de una
## habilidad en reutilización o de una poción sin cargas o en reutilización hacen parpadear su casilla.
## Las entradas sustituidas no cuentan.
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


## Una acción ha fallado por falta de resistencia: la esquiva parpadea (como la barra de resistencia).
func notify_no_stamina() -> void:
	_slots[Slot.DODGE].blink()


# --- Interno ----------------------------------------------------------------------------------

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


# Iconos y tooltips del arma activa, de sus habilidades, de las pociones y del arma de la otra ranura.
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
	# Las reutilizaciones son de otra arma: ninguna acaba «sola» en este cambio.
	for kind: int in [Slot.ABILITY_1, Slot.ABILITY_2, Slot.ABILITY_3]:
		_last_ready[kind] = -1


## true si [param weapon] dispara (su fuerte lleva proyectil): el arco.
static func is_ranged(weapon: WeaponTicks) -> bool:
	if weapon == null:
		return false
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	return heavy != null and heavy.projectile_id != 0


# Cambia [member UIIconSlot.enabled] y [member UIIconSlot.selected] solo si cambian (cada asignación vuelve a
# dibujar la casilla, y la barra se pone al día cada fotograma).
static func _set_flags(slot: ActionSlot, enabled: bool, selected: bool) -> void:
	if slot.enabled != enabled:
		slot.enabled = enabled
	if slot.selected != selected:
		slot.selected = selected


static func _set_tooltip(slot: ActionSlot, title: String, body: String = "") -> void:
	slot.set_tooltip_info(title, body)
	slot.tooltip_text = title if body.is_empty() else "%s\n%s" % [title, body]


# Reutilización de la casilla [param kind]: lista en [param ready_tick], de [param total_ticks].
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
			# Acabó sola: termina el barrido con su destello.
			slot.advance(slot.get_cooldown_remaining())
		else:
			# Un rechazo (la reconciliación quitó la habilidad) o un cambio de arma: lista sin destello.
			slot.clear_cooldown()
