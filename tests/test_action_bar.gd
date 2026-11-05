extends TestCase
## Tests of the action bar (UI-11, docs/abilities.md, sections 6.3 and 7.3, H4): it reads the predicted
## state, so it is fed with the physics-free action machine ([MachineDriver]) or with real
## prediction ([PredictionPair]).
## [br]- When the weapon changes, the icons change (abilities, attack, block hidden with the bow and the weapon
## of the other slot on Q) and each weapon keeps its cooldowns.
## [br]- [b]A rejection reverts the counter[/b]: the reconciliation that removes the ability leaves the slot
## ready, with no flash.
## [br]- A cooldown that ends by itself flashes; potions show their charges and are crossed out without them;
## pressing at the wrong time makes the slot blink; the dodge blinks without stamina.

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
	assert_eq(_title(bar, Slot.ABILITY_1), "Golpe de escudo", "slot 1 is the shield bash")
	assert_eq(_title(bar, Slot.ABILITY_2), "Embestida")
	assert_eq(_title(bar, Slot.ABILITY_3), "Muro de escudos")
	assert_true(bar.get_slot(Slot.ABILITY_1).icon is GameIcon, "icon drawn, not a letter")
	assert_eq(_letter(bar, Slot.ABILITY_1), "", "no letter")
	assert_true(bar.get_slot(Slot.PRIMARY).icon is GameIcon)
	assert_true(bar.get_slot(Slot.BLOCK).visible, "sword and shield blocks")
	assert_eq((bar.get_slot(Slot.SWAP).icon as GameIcon).figure.resource_path,
			"res://assets/ui/icons/weapon_bow.png", "Q shows the weapon of the other slot (the bow)")
	assert_eq(_title(bar, Slot.SWAP), CombatText.TEXT_SWAP_TO % "Arco")
	assert_eq(bar.get_slot(Slot.SWAP).key_action, &"swap_weapon", "with the glyph of its key")
	assert_eq(bar.get_slot(Slot.CONSUMABLE_2).key_action, &"consumable_2")
	var sword_icon: Texture2D = bar.get_slot(Slot.ABILITY_1).icon
	# Shield bash: after its commitment, slot 1 goes on cooldown.
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	d.step(PlayerInput.ABILITY_1)
	d.hold(0, bash.total_ticks + 1)
	bar.refresh(d.c, d.tick)
	var slot_1: ActionBar.ActionSlot = bar.get_slot(Slot.ABILITY_1)
	assert_true(slot_1.is_on_cooldown(), "the shield bash is on cooldown")
	var remaining: float = slot_1.get_cooldown_remaining()
	assert_near(remaining, float(d.c.ability_ready[0] - d.tick) / 60.0, 0.0001,
			"what remains comes from ability_ready - predicted tick")
	# Weapon swap (Q): the bow.
	d.step(PlayerInput.SWAP_WEAPON)
	d.hold(0, CombatCatalog.tables().swap_ticks + 1)
	bar.refresh(d.c, d.tick)
	assert_eq(bar.get_shown_weapon(), CombatCatalog.weapon_id(&"bow"), "carries the bow")
	assert_eq(_title(bar, Slot.ABILITY_1), "Abanico", "the icons are the bow's")
	assert_eq(_title(bar, Slot.ABILITY_2), "Flecha lastrante")
	assert_eq(_title(bar, Slot.ABILITY_3), "Salto atrás con disparo")
	assert_true(bar.get_slot(Slot.ABILITY_1).icon != sword_icon, "a different icon")
	assert_eq((bar.get_slot(Slot.PRIMARY).icon as GameIcon).figure.resource_path,
			"res://assets/ui/icons/bow_quick.png", "the light attack is the quick shot")
	assert_eq(_title(bar, Slot.PRIMARY), CombatText.TEXT_QUICK_SHOT)
	assert_false(bar.get_slot(Slot.BLOCK).visible, "the bow does not block: the slot is hidden")
	assert_eq(_title(bar, Slot.SWAP), CombatText.TEXT_SWAP_TO % "Espada y escudo")
	assert_false(bar.get_slot(Slot.ABILITY_1).is_on_cooldown(), "the fan is ready")
	assert_near(bar.get_slot(Slot.ABILITY_1).get_flash_alpha(), 0.0, 0.0001, "and does not flash on swap")
	# Back to the sword: the shield bash is still on cooldown (absolute ticks).
	d.step(PlayerInput.SWAP_WEAPON)
	d.hold(0, CombatCatalog.tables().swap_ticks + 1)
	bar.refresh(d.c, d.tick)
	assert_eq(_title(bar, Slot.ABILITY_1), "Golpe de escudo")
	assert_true(bar.get_slot(Slot.ABILITY_1).is_on_cooldown(), "the cooldown is kept")
	assert_near(bar.get_slot(Slot.ABILITY_1).get_cooldown_remaining(),
			float(d.c.ability_ready[0] - d.tick) / 60.0, 0.0001)


func test_a_rejection_reverts_the_counter() -> void:
	# The shield bash press is lost: the server does not start the ability; the client
	# predicted it and, on reconciling, removes it (like test_ability_reconciliation).
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
			assert_near(slot.get_flash_alpha(), 0.0, 0.0001, "a rejection does not flash")
	assert_true(was_counting, "the bar counted the predicted cooldown")
	assert_true(reverted_at > 0, "and removed it on reconciling")
	assert_true(reverted_at < PRESS_TICK + bash.cast_ticks + bash.cooldown_ticks,
			"long before it would have ended by itself (tick %d)" % reverted_at)
	assert_eq(_pair.client.combat.ability_ready[0], 0, "the predicted state no longer has it")
	assert_eq(ActionMachine.ability_status(_pair.client.combat, 0, _pair.client.last_input_tick),
			ActionMachine.AbilityStatus.READY, "the slot is ready again")
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
	assert_true(slot.is_on_cooldown(), "one tick earlier, not yet")
	bar.refresh(d.c, d.c.ability_ready[0])
	assert_false(slot.is_on_cooldown(), "at ability_ready, ready")
	assert_true(finished[0], "ends by itself")
	assert_true(slot.get_flash_alpha() > 0.9, "with its flash")


func test_potions_show_their_charges_cross_out_when_empty_and_blink_when_pressed_too_soon() -> void:
	var bar: ActionBar = _make_bar()
	var d := MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), 0, CombatState.pack_charges(1, 2))
	d.step()
	bar.refresh(d.c, d.tick)
	var health: ActionBar.ActionSlot = bar.get_slot(Slot.CONSUMABLE_1)
	var stamina: ActionBar.ActionSlot = bar.get_slot(Slot.CONSUMABLE_2)
	assert_eq(_title(bar, Slot.CONSUMABLE_1), "Poción de vida")
	assert_eq(health.get_count_text(), "1", "the charges are shown even if one is left")
	assert_eq(stamina.get_count_text(), "2")
	assert_false(health.crossed)
	assert_eq(_letter(bar, Slot.SWAP), "", "without a second weapon, Q is empty")
	assert_false(bar.get_slot(Slot.SWAP).enabled)
	# Drinks the health one: the charge is spent when the drinking ends and the shared cooldown starts.
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.consumable_ids()[0])
	d.step(PlayerInput.CONSUMABLE_1)
	d.hold(0, potion.total_ticks + 1)
	bar.refresh(d.c, d.tick)
	assert_true(health.crossed, "no charges, crossed out")
	assert_false(health.enabled)
	assert_eq(health.get_count_text(), "")
	assert_true(stamina.is_on_cooldown(), "the cooldown is shared")
	# Pressing at the wrong time (on the client; it does not travel) makes the slot blink.
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
	assert_true(stamina.is_blinking(), "on cooldown it blinks")
	press = PlayerInput.new()
	press.tick = d.tick + 2
	press.buttons = PlayerInput.CONSUMABLE_2 | PlayerInput.CONSUMABLE_1
	bar.handle_input(press)
	assert_eq(stamina.get_blink_count(), 1, "holding is not another press")
	assert_true(health.is_blinking(), "without charges it also blinks")
	var substituted := PlayerInput.new()
	substituted.tick = d.tick + 3
	substituted.buttons = PlayerInput.ABILITY_1 | PlayerInput.SUBSTITUTED
	bar.handle_input(substituted)
	assert_eq(bar.get_slot(Slot.ABILITY_1).get_blink_count(), 0, "a replaced one does not count")
	# The dodge blinks when something fails for lack of stamina and goes dark when exhausted.
	bar.notify_no_stamina()
	assert_true(bar.get_slot(Slot.DODGE).is_blinking())
	d.c.combat_flags |= CombatState.FLAG_EXHAUSTED
	bar.refresh(d.c, d.tick)
	assert_false(bar.get_slot(Slot.DODGE).enabled, "exhausted, the dodge goes dark")
	assert_false(bar.get_slot(Slot.BLOCK).enabled, "and the block")
	bar.refresh(d.c, d.tick, ActionBar.BLINK_SECONDS + 0.1)
	assert_false(bar.get_slot(Slot.DODGE).is_blinking(), "the blink ends")


## Walks and taps the shield bash at [constant PRESS_TICK] (a single tick).
func _tap_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 20:
		return input
	input.move = Vector2(0.3, 1.0).limit_length(1.0)
	if tick == PRESS_TICK:
		input.buttons |= PlayerInput.ABILITY_1
	return input
