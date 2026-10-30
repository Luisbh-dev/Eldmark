extends TestCase
## Pruebas de la barra de acciones (UI-11, docs/habilidades.md, secciones 6.3 y 7.3, H4): lee el estado
## predicho, así que se alimenta con la máquina de acciones sin física ([MachineDriver]) o con la
## predicción de verdad ([PredictionPair]).
## [br]- Al cambiar de arma cambian los iconos (habilidades, ataque, bloqueo oculto con el arco y el arma
## de la otra ranura en Q) y cada arma conserva sus reutilizaciones.
## [br]- [b]Un rechazo revierte el contador[/b]: la reconciliación que quita la habilidad deja la casilla
## lista, sin destello.
## [br]- La reutilización que acaba sola destella; las pociones enseñan sus cargas y se tachan sin ellas;
## pulsar a destiempo hace parpadear la casilla; la esquiva parpadea sin resistencia.

const Slot = ActionBar.Slot
const PRESS_TICK: int = 40
const FRAMES: int = 160

var _nodes: Array[Node] = []
var _pair: PredictionPair = null


func before_each() -> void:
	InputBindings.ensure_defaults()


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _make_bar() -> ActionBar:
	var bar := ActionBar.new()
	tree.root.add_child(bar)
	_nodes.append(bar)
	return bar


func _letter(bar: ActionBar, kind: int) -> String:
	var icon: PlaceholderIcon = bar.get_slot(kind).icon as PlaceholderIcon
	return icon.letter if icon != null else ""


func _title(bar: ActionBar, kind: int) -> String:
	return String(bar.get_slot(kind).tooltip_info.get("title", ""))


func _driver() -> MachineDriver:
	return MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), CombatCatalog.weapon_id(&"bow"),
			CombatState.pack_charges(3, 2))


func test_swapping_weapons_changes_the_icons_and_keeps_each_weapons_cooldowns() -> void:
	var bar: ActionBar = _make_bar()
	var d: MachineDriver = _driver()
	d.step()
	bar.refresh(d.c, d.tick)
	assert_eq(bar.get_shown_weapon(), CombatCatalog.weapon_id(&"sword_shield"))
	assert_eq(_title(bar, Slot.ABILITY_1), "Golpe de escudo", "la ranura 1 es el golpe de escudo")
	assert_eq(_title(bar, Slot.ABILITY_2), "Embestida")
	assert_eq(_title(bar, Slot.ABILITY_3), "Muro de escudos")
	assert_eq(_letter(bar, Slot.ABILITY_1), "G", "icono provisional con su inicial")
	assert_eq(_letter(bar, Slot.PRIMARY), ActionBar.LETTER_ATTACK)
	assert_true(bar.get_slot(Slot.BLOCK).visible, "la espada y escudo bloquea")
	assert_eq(_letter(bar, Slot.SWAP), "A", "Q enseña el arma de la otra ranura (el arco)")
	assert_eq(_title(bar, Slot.SWAP), CombatText.TEXT_SWAP_TO % "Arco")
	assert_eq(bar.get_slot(Slot.SWAP).key_action, &"swap_weapon", "con el glifo de su tecla")
	assert_eq(bar.get_slot(Slot.CONSUMABLE_2).key_action, &"consumable_2")
	var sword_icon: Texture2D = bar.get_slot(Slot.ABILITY_1).icon
	# Golpe de escudo: tras su compromiso, la casilla 1 entra en reutilización.
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	d.step(PlayerInput.ABILITY_1)
	d.hold(0, bash.total_ticks + 1)
	bar.refresh(d.c, d.tick)
	var slot_1: ActionBar.ActionSlot = bar.get_slot(Slot.ABILITY_1)
	assert_true(slot_1.is_on_cooldown(), "el golpe de escudo está en reutilización")
	var remaining: float = slot_1.get_cooldown_remaining()
	assert_near(remaining, float(d.c.ability_ready[0] - d.tick) / 60.0, 0.0001,
			"lo que falta sale de ability_ready − tick predicho")
	# Cambio de arma (Q): el arco.
	d.step(PlayerInput.SWAP_WEAPON)
	d.hold(0, CombatCatalog.tables().swap_ticks + 1)
	bar.refresh(d.c, d.tick)
	assert_eq(bar.get_shown_weapon(), CombatCatalog.weapon_id(&"bow"), "lleva el arco")
	assert_eq(_title(bar, Slot.ABILITY_1), "Abanico", "los iconos son los del arco")
	assert_eq(_title(bar, Slot.ABILITY_2), "Flecha lastrante")
	assert_eq(_title(bar, Slot.ABILITY_3), "Salto atrás con disparo")
	assert_true(bar.get_slot(Slot.ABILITY_1).icon != sword_icon, "otro icono")
	assert_eq(_letter(bar, Slot.PRIMARY), ActionBar.LETTER_SHOT, "el ligero es el disparo rápido")
	assert_eq(_title(bar, Slot.PRIMARY), CombatText.TEXT_QUICK_SHOT)
	assert_false(bar.get_slot(Slot.BLOCK).visible, "el arco no bloquea: la casilla se oculta")
	assert_eq(_title(bar, Slot.SWAP), CombatText.TEXT_SWAP_TO % "Espada y escudo")
	assert_false(bar.get_slot(Slot.ABILITY_1).is_on_cooldown(), "el abanico está listo")
	assert_near(bar.get_slot(Slot.ABILITY_1).get_flash_alpha(), 0.0, 0.0001, "y no destella al cambiar")
	# De vuelta a la espada: el golpe de escudo sigue en reutilización (ticks absolutos).
	d.step(PlayerInput.SWAP_WEAPON)
	d.hold(0, CombatCatalog.tables().swap_ticks + 1)
	bar.refresh(d.c, d.tick)
	assert_eq(_title(bar, Slot.ABILITY_1), "Golpe de escudo")
	assert_true(bar.get_slot(Slot.ABILITY_1).is_on_cooldown(), "la reutilización se conserva")
	assert_near(bar.get_slot(Slot.ABILITY_1).get_cooldown_remaining(),
			float(d.c.ability_ready[0] - d.tick) / 60.0, 0.0001)


func test_a_rejection_reverts_the_counter() -> void:
	# La pulsación del golpe de escudo se pierde: el servidor no empieza la habilidad; el cliente la
	# predijo y, al reconciliar, la quita (como test_ability_reconciliation).
	_pair = PredictionPair.new()
	_pair.lost.assign([PRESS_TICK])
	_pair.state_delay_frames = 30
	var combat: CombatState = CombatState.initial(CombatCatalog.rules(),
			CombatCatalog.weapon_id(&"sword_shield"), 0, CombatState.pack_charges(3, 2))
	await _pair.build(tree, _tap_route, combat)
	var bar: ActionBar = _make_bar()
	bar.bind(_pair.client)
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var was_counting: bool = false
	var reverted_at: int = -1
	for _frame: int in FRAMES:
		await tree.physics_frame
		_pair.frame()
		bar.refresh(_pair.client.combat, _pair.client.last_input_tick, 1.0 / 60.0)
		var slot: ActionBar.ActionSlot = bar.get_slot(Slot.ABILITY_1)
		if slot.is_on_cooldown():
			was_counting = true
		elif was_counting and reverted_at < 0:
			reverted_at = _pair.prediction.get_predicted_tick()
			assert_near(slot.get_flash_alpha(), 0.0, 0.0001, "un rechazo no destella")
	assert_true(was_counting, "la barra contó la reutilización predicha")
	assert_true(reverted_at > 0, "y la quitó al reconciliar")
	assert_true(reverted_at < PRESS_TICK + bash.cast_ticks + bash.cooldown_ticks,
			"mucho antes de que acabara sola (tick %d)" % reverted_at)
	assert_eq(_pair.client.combat.ability_ready[0], 0, "el estado predicho ya no la tiene")
	assert_eq(ActionMachine.ability_status(_pair.client.combat, 0, _pair.client.last_input_tick),
			ActionMachine.AbilityStatus.READY, "la casilla vuelve a estar lista")
	assert_true(bar.get_slot(Slot.ABILITY_1).enabled)


func test_a_cooldown_that_ends_on_its_own_flashes() -> void:
	var bar: ActionBar = _make_bar()
	var d: MachineDriver = _driver()
	d.step(PlayerInput.ABILITY_1)
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	d.hold(0, bash.cast_ticks + 2)
	bar.refresh(d.c, d.tick)
	var slot: ActionBar.ActionSlot = bar.get_slot(Slot.ABILITY_1)
	assert_true(slot.is_on_cooldown())
	var finished: Array[bool] = [false]
	slot.cooldown_finished.connect(func() -> void: finished[0] = true)
	bar.refresh(d.c, d.c.ability_ready[0] - 1)
	assert_true(slot.is_on_cooldown(), "un tick antes, aún no")
	bar.refresh(d.c, d.c.ability_ready[0])
	assert_false(slot.is_on_cooldown(), "en ability_ready, lista")
	assert_true(finished[0], "acaba sola")
	assert_true(slot.get_flash_alpha() > 0.9, "con su destello")


func test_potions_show_their_charges_cross_out_when_empty_and_blink_when_pressed_too_soon() -> void:
	var bar: ActionBar = _make_bar()
	var d := MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), 0, CombatState.pack_charges(1, 2))
	d.step()
	bar.refresh(d.c, d.tick)
	var health: ActionBar.ActionSlot = bar.get_slot(Slot.CONSUMABLE_1)
	var stamina: ActionBar.ActionSlot = bar.get_slot(Slot.CONSUMABLE_2)
	assert_eq(_title(bar, Slot.CONSUMABLE_1), "Poción de vida")
	assert_eq(health.get_count_text(), "1", "las cargas se ven aunque quede una")
	assert_eq(stamina.get_count_text(), "2")
	assert_false(health.crossed)
	assert_eq(_letter(bar, Slot.SWAP), "", "sin segunda arma, Q vacía")
	assert_false(bar.get_slot(Slot.SWAP).enabled)
	# Bebe la de vida: se gasta la carga al acabar de beber y entra la reutilización compartida.
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.consumable_ids()[0])
	d.step(PlayerInput.CONSUMABLE_1)
	d.hold(0, potion.total_ticks + 1)
	bar.refresh(d.c, d.tick)
	assert_true(health.crossed, "sin cargas, tachada")
	assert_false(health.enabled)
	assert_eq(health.get_count_text(), "")
	assert_true(stamina.is_on_cooldown(), "la reutilización es compartida")
	# Pulsar a destiempo (en el cliente; no viaja) hace parpadear la casilla.
	bar.bind(null)
	var character: PlayerCharacter = (load("res://scenes/characters/player_character.tscn") as PackedScene) \
			.instantiate() as PlayerCharacter
	_nodes.append(character)
	character.combat.copy_from(d.c)
	character.last_input_tick = d.tick
	bar.bind(character)
	var press := PlayerInput.new()
	press.tick = d.tick + 1
	press.buttons = PlayerInput.CONSUMABLE_2
	bar.handle_input(press)
	assert_true(stamina.is_blinking(), "en reutilización parpadea")
	press = PlayerInput.new()
	press.tick = d.tick + 2
	press.buttons = PlayerInput.CONSUMABLE_2 | PlayerInput.CONSUMABLE_1
	bar.handle_input(press)
	assert_eq(stamina.get_blink_count(), 1, "mantener no es otra pulsación")
	assert_true(health.is_blinking(), "sin cargas también parpadea")
	var substituted := PlayerInput.new()
	substituted.tick = d.tick + 3
	substituted.buttons = PlayerInput.ABILITY_1 | PlayerInput.SUBSTITUTED
	bar.handle_input(substituted)
	assert_eq(bar.get_slot(Slot.ABILITY_1).get_blink_count(), 0, "una sustituida no cuenta")
	# La esquiva parpadea cuando algo falla por falta de resistencia y se apaga agotado.
	bar.notify_no_stamina()
	assert_true(bar.get_slot(Slot.DODGE).is_blinking())
	d.c.combat_flags |= CombatState.FLAG_EXHAUSTED
	bar.refresh(d.c, d.tick)
	assert_false(bar.get_slot(Slot.DODGE).enabled, "agotado, la esquiva se apaga")
	assert_false(bar.get_slot(Slot.BLOCK).enabled, "y el bloqueo")
	bar.refresh(d.c, d.tick, ActionBar.BLINK_SECONDS + 0.1)
	assert_false(bar.get_slot(Slot.DODGE).is_blinking(), "el parpadeo acaba")


## Camina y toca el golpe de escudo en [constant PRESS_TICK] (un solo tick).
func _tap_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 20:
		return input
	input.move = Vector2(0.3, 1.0).limit_length(1.0)
	if tick == PRESS_TICK:
		input.buttons |= PlayerInput.ABILITY_1
	return input
