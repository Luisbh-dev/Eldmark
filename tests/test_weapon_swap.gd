extends TestCase
## Cambio de arma (docs/habilidades.md, secciones 3.3 a 3.5 y 7.3): intercambio de las armas y de las
## dos mitades de las reutilizaciones, nunca a mitad de un golpe (al búfer, y caduca si no llega), sin
## arma en la otra ranura no hace nada, [method ActionMachine.set_charges] no toca nada más y
## [method ActionMachine.set_loadout] fuerza NONE sobre un vivo. Con física ([PredictionPair]): el
## cambio predicho y reconciliado con una entrada sustituida alrededor del flanco acaba igual en los
## dos lados.

const Action = CombatState.Action
const PRIMARY: int = PlayerInput.PRIMARY
const DODGE: int = PlayerInput.DODGE
const SWAP: int = PlayerInput.SWAP_WEAPON
const ABILITY_1: int = PlayerInput.ABILITY_1
const ABILITY_3: int = PlayerInput.ABILITY_3
## Tick del flanco de SWAP en la prueba con física.
const SWAP_TICK: int = 40

var _pair: PredictionPair


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	await wait_process_frames()


func test_swap_exchanges_the_weapons_and_the_two_cooldown_halves() -> void:
	var data: CombatTables = CombatCatalog.tables()
	assert_eq(data.swap_ticks, 24, "0,4 s")
	var d := _driver()
	d.step(ABILITY_1)
	d.hold(0, 60)
	var bash_ready: int = d.c.ability_ready[0]
	assert_true(bash_ready > 0, "golpe de escudo en reutilización")
	d.step(SWAP)
	var s: int = d.tick
	assert_eq(d.c.action, Action.SWAP, "cambiando")
	assert_eq(d.c.action_tick, s, "desde el flanco")
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_bow(), _sword()], "el arma cambia en el primer tick")
	assert_true(d.c.is_second_slot(), "la ranura 2 está activa")
	assert_eq(d.c.ability_ready.slice(0, 3), PackedInt64Array([0, 0, 0]), "las del arco, libres")
	assert_eq(d.c.ability_ready[3], bash_ready, "la del escudo, guardada en la otra mitad")
	assert_true(d.out.scaled_movement, "movimiento escalado")
	assert_near(d.out.move_scale, 0.8, 1e-6, "×0,8")
	assert_eq(d.out.turn_rate, -1.0, "giro normal")
	assert_false(d.out.allow_jump or d.out.allow_sprint, "sin salto ni esprint")
	assert_eq(ActionMachine.phase(d.c, s), ActionMachine.PHASE_NONE, "sin fases")
	d.idle_until_before(s + 24)
	assert_eq(d.c.action, Action.SWAP, "dura 24 ticks")
	d.step()
	assert_eq(d.c.action, Action.NONE, "y acaba")
	# Las reutilizaciones son ticks absolutos: corren con el arma guardada.
	d.step(SWAP)
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_sword(), _bow()], "de vuelta a la espada")
	assert_false(d.c.is_second_slot(), "ranura 1")
	assert_eq(d.c.ability_ready[0], bash_ready, "la reutilización vuelve con su arma, intacta")
	assert_eq(d.c.ability_ready[3], 0, "y la mitad del arco queda guardada")
	# También en el aire.
	var air := _driver()
	air.grounded = false
	air.step(SWAP)
	assert_eq(air.c.action, Action.SWAP, "se cambia en el aire")


func test_no_swap_in_the_middle_of_a_hit() -> void:
	# Pulsado en el golpe activo de un ligero: el arma no cambia hasta la recuperación (rel 18).
	var d := _driver()
	d.step(PRIMARY)
	var p: int = d.tick
	d.idle_until_before(p + 13)
	d.step(SWAP)
	assert_eq(d.c.action, Action.LIGHT, "a mitad de golpe no se cambia")
	assert_eq(d.c.weapon_id, _sword(), "el arma sigue")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_SWAP, "va al búfer")
	d.idle_until_before(p + 18)
	assert_eq(d.c.weapon_id, _sword(), "hasta la recuperación, nada")
	d.step()
	assert_eq(d.c.action, Action.SWAP, "en la recuperación cambia")
	assert_eq(d.c.action_tick, p + 18, "en su primer tick")
	assert_eq(d.c.weapon_id, _bow(), "con el arma nueva")
	# Pulsado en la anticipación: el búfer caduca antes de la recuperación.
	var early := _driver()
	early.step(PRIMARY)
	var q: int = early.tick
	early.step(SWAP)
	early.idle_until_before(q + 40)
	assert_eq(early.c.weapon_id, _sword(), "caducó: no hay cambio")
	assert_eq(early.c.alt_weapon_id, _bow(), "las armas siguen igual")
	# Ni en la carga, ni en el lanzamiento o la canalización de una habilidad.
	var charge := _driver()
	charge.hold(PRIMARY, 8)
	charge.step(PRIMARY | SWAP)
	assert_eq(charge.c.action, Action.CHARGE, "cargando no se cambia")
	var wall := _driver()
	wall.step(ABILITY_3)
	wall.hold(ABILITY_3, 5)
	wall.step(ABILITY_3 | SWAP)
	assert_eq(wall.c.action, Action.ABILITY, "lanzando no")
	wall.hold(ABILITY_3, 20)
	wall.step(ABILITY_3 | SWAP)
	assert_eq(wall.c.action, Action.ABILITY, "canalizando no")
	assert_eq(wall.c.weapon_id, _sword(), "el arma sigue")
	# Desde la esquiva, desde su cancel_to_attack_from (18).
	var dodge := _driver()
	dodge.step(DODGE)
	var r: int = dodge.tick
	dodge.idle_until_before(r + 10)
	dodge.step(SWAP)
	assert_eq(dodge.c.action, Action.DODGE, "esquivando, aún no")
	dodge.idle_until_before(r + 19)
	assert_eq(dodge.c.action, Action.SWAP, "desde el tick 18 de la esquiva")
	assert_eq(dodge.c.action_tick, r + 18, "justo ahí")


func test_without_a_second_weapon_the_press_is_dropped() -> void:
	var d := MachineDriver.new(_sword(), 0, CombatState.pack_charges(3, 2))
	d.step(SWAP)
	assert_eq(d.c.action, Action.NONE, "sin otra arma no hay cambio")
	assert_eq(d.c.buffered, 0, "ni se guarda")
	assert_eq(d.c.weapon_id, _sword(), "el arma sigue")


func test_a_buffered_swap_starts_when_the_other_ends() -> void:
	var d := _driver()
	d.step(SWAP)
	var s: int = d.tick
	d.idle_until_before(s + 20)
	d.step(SWAP)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_SWAP, "el segundo cambio espera")
	d.idle_until_before(s + 25)
	assert_eq(d.c.action, Action.SWAP, "sale en el tick en que acaba el primero, sin NONE")
	assert_eq(d.c.action_tick, s + 24, "en ese tick")
	assert_eq(d.c.weapon_id, _sword(), "de vuelta a la espada")
	var wire := ActionWire.new()
	var first := MachineDriver.new(_sword(), _bow())
	first.step(SWAP)
	var byte_first: int = wire.encode(first.c, first.tick)
	first.idle_until_before(first.tick + 20)
	first.step(SWAP)
	first.idle_until_before(first.c.action_tick + 25)
	var byte_second: int = wire.encode(first.c, first.tick)
	assert_eq(byte_first & 0x3F, byte_second & 0x3F, "mismo byte de acción y fase")
	assert_true(ActionWire.step_of(byte_first) != ActionWire.step_of(byte_second),
			"pero otro contador: el remoto reinicia la animación")


func test_set_charges_touches_nothing_else() -> void:
	var d := _driver()
	d.step(SWAP)
	d.hold(0, 30)
	d.step(ABILITY_1)
	d.hold(ABILITY_1, 30)
	assert_true(d.c.is_second_slot(), "con la ranura 2 activa")
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 5)
	assert_eq(d.c.action, Action.ABILITY, "y una habilidad en curso")
	assert_true(d.c.ability_ready[0] > 0, "con su reutilización fijada")
	var before: PackedByteArray = d.bytes()
	ActionMachine.set_charges(d.c, CombatState.pack_charges(7, 1))
	var after: PackedByteArray = d.bytes()
	assert_eq(d.c.consumable_charges, CombatState.pack_charges(7, 1), "cambian las cargas")
	for i: int in CombatState.ENCODED_SIZE:
		if i == 65:
			continue
		if before[i] != after[i]:
			fail("set_charges cambió el byte %d (offset %d en PlayerState)" % [i, i + 35])
			return
	assert_eq(d.c.action, Action.ABILITY, "la habilidad sigue")


func test_set_loadout_forces_none_on_a_living_character_and_reset_takes_the_template() -> void:
	var d := _driver()
	d.c.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	d.step(PRIMARY | ABILITY_3)
	d.step(ABILITY_1 | ABILITY_3)
	ActionMachine.impose_move_effect(d.c, CombatCatalog.status_id(&"slowed"), d.tick + 100)
	ActionMachine.set_loadout(d.c, _bow(), _sword(), CombatState.pack_charges(2, 3))
	assert_eq(d.c.action, Action.NONE, "sobre un vivo, antes NONE")
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_bow(), _sword()], "armas en orden de ranura")
	assert_false(d.c.is_second_slot(), "con la 1 activa")
	assert_eq(d.c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "reutilizaciones a 0")
	assert_eq(d.c.consumable_charges, CombatState.pack_charges(2, 3), "cargas")
	assert_eq(d.c.move_effect_ids, PackedInt32Array([0, 0]), "ranuras vacías")
	assert_eq(d.c.buffered, 0, "sin búfer")
	assert_eq(d.c.combat_flags2 & CombatState.FLAG2_HELD_MASK,
			CombatState.FLAG2_ABILITY_1_HELD | CombatState.FLAG2_ABILITY_3_HELD,
			"conserva los botones pulsados")
	d.step(ABILITY_1 | ABILITY_3)
	assert_eq(d.c.action, Action.NONE, "sin flancos al seguir mantenidos")
	var dead := _driver()
	dead.step()
	ActionMachine.impose_death(dead.c, dead.tick)
	ActionMachine.set_loadout(dead.c, _bow(), 0, 0)
	assert_eq(dead.c.action, Action.DEAD, "sobre un muerto solo cambia el equipo")
	assert_eq(dead.c.weapon_id, _bow(), "el arco")


func test_a_predicted_swap_is_reconciled_around_a_substituted_edge() -> void:
	# La entrada del flanco se pierde: el servidor la sustituye (sin SWAP) y cambia un tick tarde, con
	# la siguiente real. El cliente corrige y acaba igual, byte a byte.
	_pair = PredictionPair.new()
	_pair.lost.assign([SWAP_TICK])
	await _pair.build(tree, _swap_route, _pair_combat())
	for _frame: int in 120:
		await tree.physics_frame
		_pair.frame()
	var server_start: int = -1
	for tick: int in range(SWAP_TICK - 1, SWAP_TICK + 4):
		var state: PlayerState = _pair.server_states[tick]
		if state.combat.action == Action.SWAP and server_start < 0:
			server_start = state.combat.action_tick
	assert_eq(server_start, SWAP_TICK + 1, "el servidor cambia con la primera entrada real")
	assert_true(_pair.results_not(ClientPrediction.Result.MATCH).size() >= 1, "el cliente corrige")
	var since: int = _pair.converged_since(SWAP_TICK)
	assert_true(since > 0 and since <= SWAP_TICK + 4, "y acaba igual que el servidor (desde %d)" % since)
	var last: PlayerState = _pair.predicted(_pair.server_tick)
	assert_eq(last.combat.weapon_id, _bow(), "con el arco")
	# Y si se pierde la entrada siguiente al flanco, la sustituta repite el botón: nada que corregir.
	_pair.free_worlds()
	_pair = PredictionPair.new()
	_pair.lost.assign([SWAP_TICK + 1])
	await _pair.build(tree, _swap_route, _pair_combat())
	for _frame: int in 120:
		await tree.physics_frame
		_pair.frame()
	assert_eq(_pair.results_not(ClientPrediction.Result.MATCH).size(), 0,
			"perder el tick siguiente al flanco no cambia nada")
	assert_eq((_pair.server_states[SWAP_TICK] as PlayerState).combat.action, Action.SWAP,
			"el servidor cambió en el flanco")


func _sword() -> int:
	return CombatCatalog.weapon_id(&"sword_shield")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")


func _driver() -> MachineDriver:
	return MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(2, 3))


func _pair_combat() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), _sword(), _bow(), CombatState.pack_charges(2, 3))


## Camina y mantiene SWAP de [constant SWAP_TICK] a [constant SWAP_TICK] + 5.
func _swap_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 20:
		return input
	input.move = Vector2(0.0, 1.0)
	if tick >= SWAP_TICK and tick <= SWAP_TICK + 5:
		input.buttons |= SWAP
	return input
