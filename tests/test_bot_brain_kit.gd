extends TestCase
## El kit de la fase 4 en [BotBrain] (H5; docs/habilidades.md, sección 7.1), sin red ni física: el estado de
## combate del bot es el de una máquina de acciones que avanza con sus propias entradas ([ActionMachine]), y los
## enemigos y aliados los dan buscadores a mano. Se comprueba que usa las habilidades solo cuando valen y mantiene
## el botón del muro, que bebe y cambia de arma cuando toca, que el arco apunta con el tiro adelantado (las
## flechas que calcula [ProjectileLaunch] dan en un blanco que corre), que remata y levanta manteniendo INTERACT,
## y que sin estado de combate (o con [member BotBrain.use_kit] apagado) el bot es el de la fase 3.

const START_TICK: int = 1000


## Un bot con su máquina de acciones: [member c] es su estado de combate (el que lee el kit), que avanza con las
## entradas que genera el bot.
class Rig:
	extends RefCounted

	var c: CombatState
	var brain: BotBrain
	var tick: int = START_TICK
	var position: Vector3 = Vector3.ZERO
	var inputs: Array[PlayerInput] = []
	## Tick de cada pulsación (flanco) de una habilidad o un consumible -> estado de su casilla en ese tick.
	var presses: Array[Vector3i] = []

	## Un tick: la entrada del bot (cuantizada, como viaja) y el paso de la máquina.
	func step() -> PlayerInput:
		var t: int = tick + 1
		var input: PlayerInput = brain.next_input(t, position, 0.0).quantized()
		input.tick = t
		var previous: int = inputs[inputs.size() - 1].buttons if not inputs.is_empty() else 0
		for slot: int in 5:
			var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3,
					PlayerInput.CONSUMABLE_1, PlayerInput.CONSUMABLE_2][slot]
			if (input.buttons & button) != 0 and (previous & button) == 0:
				presses.append(Vector3i(t, slot, ActionMachine.ability_status(c, slot, t)))
		ActionMachine.step(c, input, true)
		tick = t
		inputs.append(input)
		return input

	func run(count: int) -> void:
		for _i: int in count:
			step()


func _rig(weapon_1: StringName, weapon_2: StringName, charges: int, rng_seed: int = 7,
		enemy: Variant = null) -> Rig:
	var rig := Rig.new()
	rig.c = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(weapon_1),
			CombatCatalog.weapon_id(weapon_2) if weapon_2 != &"" else 0, charges)
	rig.brain = BotBrain.new(rng_seed, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	# El cierre guarda el estado, no el Rig (que guarda el cerebro): sin ciclos de referencias.
	var state: CombatState = rig.c
	rig.brain.set_combat_source(func() -> CombatState: return state)
	if enemy != null:
		rig.brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy)
	return rig


func _squire(enemy: Variant, rng_seed: int = 7) -> Rig:
	return _rig(&"sword_shield", &"", CombatState.pack_charges(3, 2), rng_seed, enemy)


# Pulsaciones de la casilla [param slot] (0-2 habilidades, 3-4 consumibles).
func _presses_of(rig: Rig, slot: int) -> Array[Vector3i]:
	var found: Array[Vector3i] = []
	for press: Vector3i in rig.presses:
		if press.y == slot:
			found.append(press)
	return found


# La racha más larga de ticks seguidos con [param button] pulsado.
func _longest_hold(rig: Rig, button: int) -> int:
	var longest: int = 0
	var run_length: int = 0
	for input: PlayerInput in rig.inputs:
		run_length = run_length + 1 if (input.buttons & button) != 0 else 0
		longest = maxi(longest, run_length)
	return longest


# --- Datos ------------------------------------------------------------------------------------

func test_the_role_of_each_ability_comes_from_its_data() -> void:
	var roles: Dictionary[StringName, BotBrain.KitRole] = {
		&"shield_bash": BotBrain.KitRole.CLOSE, &"shield_rush": BotBrain.KitRole.GAP_CLOSER,
		&"shield_wall": BotBrain.KitRole.GUARD, &"bow_volley": BotBrain.KitRole.SHOT,
		&"bow_slowing_shot": BotBrain.KitRole.SHOT, &"bow_evasive_shot": BotBrain.KitRole.ESCAPE,
	}
	for ability_name: StringName in roles:
		assert_eq(BotBrain.kit_role(CombatCatalog.ability(CombatCatalog.ability_id(ability_name))),
				roles[ability_name], "papel de %s" % ability_name)
	assert_eq(BotBrain.kit_role(null), BotBrain.KitRole.NONE)
	assert_true(BotBrain.is_ranged_weapon(CombatCatalog.weapon_id(&"bow")), "el arco dispara con el ligero")
	assert_false(BotBrain.is_ranged_weapon(CombatCatalog.weapon_id(&"sword_shield")))
	assert_false(BotBrain.is_ranged_weapon(0))


func test_without_a_combat_source_or_with_the_kit_off_it_fights_like_in_phase_3() -> void:
	var enemy := Vector3(2.0, 0.0, 0.0)
	var plain := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	plain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy)
	var off := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	off.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(enemy))
	var state: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"))
	off.set_combat_source(func() -> CombatState: return state)
	off.use_kit = false
	for tick: int in range(1, 601):
		var a: PlayerInput = plain.next_input(tick, Vector3.ZERO, 0.0).quantized()
		var b: PlayerInput = off.next_input(tick, Vector3.ZERO, 0.0).quantized()
		assert_eq(b.encode(), a.encode(), "mismas entradas, también con un BotTarget (tick %d)" % tick)
	assert_true(off.get_kit_counts().is_empty(), "el kit no ha hecho nada")


# --- Espada y escudo --------------------------------------------------------------------------

func test_the_squire_uses_its_abilities_only_when_they_are_ready_and_holds_the_wall() -> void:
	var rig: Rig = _squire(Vector3(0.0, 0.0, -1.6))
	var wall_id: int = CombatCatalog.ability_id(&"shield_wall")
	var wall_ticks: int = 0
	var longest_wall: int = 0
	for _i: int in 4000:
		rig.step()
		if rig.c.action == CombatState.Action.ABILITY and rig.c.action_id == wall_id:
			wall_ticks += 1
			longest_wall = maxi(longest_wall, rig.tick - rig.c.action_tick + 1)
	var counts: Dictionary[StringName, int] = rig.brain.get_kit_counts()
	print("[kit] escudero contra un enemigo a 1,6 m, 4000 ticks: %s" % [counts])
	for press: Vector3i in rig.presses:
		assert_eq(press.z, ActionMachine.AbilityStatus.READY,
				"solo pulsa una casilla lista (tick %d, casilla %d)" % [press.x, press.y])
	assert_true(_presses_of(rig, 0).size() >= 2, "golpe de escudo (%d)" % _presses_of(rig, 0).size())
	assert_true(_presses_of(rig, 2).size() >= 1, "muro (%d)" % _presses_of(rig, 2).size())
	assert_true(_longest_hold(rig, PlayerInput.ABILITY_3) >= BotBrain.KIT_GUARD_HOLD_TICKS.x,
			"mantiene el botón del muro (%d ticks)" % _longest_hold(rig, PlayerInput.ABILITY_3))
	assert_true(longest_wall >= BotBrain.KIT_GUARD_HOLD_TICKS.x,
			"y la canalización dura lo que lo mantiene (%d ticks)" % longest_wall)
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var bash_presses: Array[Vector3i] = _presses_of(rig, 0)
	for index: int in range(1, bash_presses.size()):
		assert_true(bash_presses[index].x - bash_presses[index - 1].x >= bash.cooldown_ticks,
				"dos golpes de escudo, separados al menos por su reutilización")
	assert_true(int(counts.get(&"ability_0", 0)) == bash_presses.size(), "el contador lleva la cuenta")
	assert_true((_count_button(rig, PlayerInput.PRIMARY)) > 0, "y sigue atacando con la espada")


func test_the_squire_closes_the_gap_with_the_rush() -> void:
	var rig: Rig = _squire(Vector3(0.0, 0.0, -5.0))
	rig.run(300)
	var rushes: Array[Vector3i] = _presses_of(rig, 1)
	if not assert_false(rushes.is_empty(), "a 5 m se lanza con la embestida"):
		return
	assert_eq(rushes[0].z, ActionMachine.AbilityStatus.READY)
	assert_true(_presses_of(rig, 0).is_empty(), "a 5 m no da el golpe de escudo, que no llega")


func test_it_drinks_when_hurt_or_tired_and_only_with_charges_and_off_cooldown() -> void:
	var rig: Rig = _squire(Vector3(0.0, 0.0, -20.0))
	var health: Array[float] = [0.3]
	rig.brain.set_health_source(func() -> float: return health[0])
	rig.run(4000)
	var drinks: Array[Vector3i] = _presses_of(rig, 3)
	assert_eq(drinks.size(), 3, "las tres cargas de vida del escudero, ni una más (%s)" % [drinks])
	for index: int in range(1, drinks.size()):
		assert_true(drinks[index].x - drinks[index - 1].x >= CombatCatalog.tables().consumable_cooldown_ticks,
				"separadas por la reutilización compartida")
	assert_eq(rig.c.charges_of(0), 0, "sin cargas de vida")
	# Cansado y con la vida llena: la de resistencia.
	var tired: Rig = _squire(Vector3(0.0, 0.0, -20.0))
	tired.brain.set_health_source(func() -> float: return 1.0)
	tired.c.stamina = 100
	tired.c.stamina_regen_tick = START_TICK + 100000
	tired.run(60)
	assert_eq(_presses_of(tired, 4).size(), 1, "bebe la de resistencia")
	assert_true(_presses_of(tired, 3).is_empty(), "y no la de vida")
	assert_true(tired.c.stamina >= 400, "+400 de resistencia (%d)" % tired.c.stamina)


# --- Cambio de arma y arco ------------------------------------------------------------------------

func test_the_marksman_swaps_to_the_sword_up_close_and_back_to_the_bow_at_range() -> void:
	var enemy: Array[Vector3] = [Vector3(0.0, 0.0, -3.0)]
	var rig: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 8)
	rig.brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	rig.run(60)
	assert_eq(rig.c.weapon_id, CombatCatalog.weapon_id(&"sword_shield"), "de cerca, la espada")
	assert_eq(int(rig.brain.get_kit_counts().get(&"swap", 0)), 1, "un cambio")
	enemy[0] = Vector3(0.0, 0.0, -20.0)
	rig.run(60)
	assert_eq(rig.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "de lejos, el arco")
	assert_eq(int(rig.brain.get_kit_counts().get(&"swap", 0)), 2, "y otro")
	assert_eq(rig.c.ability_ready.size(), 6, "las reutilizaciones de las dos armas siguen ahí")


func test_the_archer_leads_a_running_target_and_its_arrows_hit() -> void:
	# Un blanco a 22 m que corre en lateral a 6 m/s: cada flecha que sale (la que calcula ProjectileLaunch con la
	# entrada del tick del compromiso, la misma cuenta que el servidor) vuela contra su cápsula en movimiento.
	var velocity := Vector3(6.0, 0.0, 0.0)
	var start := Vector3(-30.0, 0.0, -22.0)
	var rig: Rig = _rig(&"bow", &"", CombatState.pack_charges(2, 3), 9)
	var now: Array[int] = [START_TICK]
	rig.brain.set_enemy_finder(func(_position: Vector3) -> Variant:
		return BotTarget.new(start + velocity * (float(now[0] + 1 - START_TICK) / 60.0), velocity))
	var shots: int = 0
	var hits: int = 0
	var drawn: int = 0
	for _i: int in 600:
		var input: PlayerInput = rig.step()
		now[0] = rig.tick
		var launch: ProjectileLaunch = ProjectileLaunch.from_state(rig.c, rig.tick)
		if launch == null:
			continue
		var target_at_commit: Vector3 = start + velocity * (float(rig.tick - START_TICK) / 60.0)
		var arrows: Array[PackedVector3Array] = launch.launch(rig.position, input.look_yaw, input.look_pitch,
				input.has(PlayerInput.AIM_LEFT), null, PackedVector3Array([target_at_commit]))
		var middle: PackedVector3Array = arrows[arrows.size() / 2]
		shots += 1
		if launch.charge_fraction > 0.0:
			drawn += 1
		if _flies_into(middle[0], middle[1], target_at_commit, velocity):
			hits += 1
	print("[kit] arquero contra un blanco que corre a 22 m: %d disparos (%d tensados), %d aciertos; %s" % [
			shots, drawn, hits, rig.brain.get_kit_counts()])
	assert_true(shots >= 8, "dispara (%d)" % shots)
	assert_true(drawn >= 1, "también tensa (%d)" % drawn)
	assert_true(hits >= shots - 1, "y casi todas dan en el blanco que corre: %d de %d" % [hits, shots])
	assert_true(_longest_hold(rig, PlayerInput.PRIMARY) >= 21, "mantiene PRIMARY para tensar")
	assert_true(rig.inputs.any(func(input: PlayerInput) -> bool: return input.look_pitch > 0.0),
			"apunta por encima del blanco (la caída)")
	assert_true(rig.inputs.all(func(input: PlayerInput) -> bool: return input.has(PlayerInput.AIM_LEFT)),
			"semilla impar: hombro izquierdo en todas sus entradas")


# true si la flecha que sale de [param p0] con [param v0] toca la cápsula de un blanco que empieza en
# [param feet] y se mueve a [param velocity] (el segmento de cada tick contra la cápsula en ese tick).
func _flies_into(p0: Vector3, v0: Vector3, feet: Vector3, velocity: Vector3) -> bool:
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	for n: int in arrow.lifetime_ticks:
		var a: Vector3 = Ballistics.position(p0, v0, arrow.gravity, float(n))
		var b: Vector3 = Ballistics.position(p0, v0, arrow.gravity, float(n + 1))
		var capsule: Vector3 = feet + velocity * (float(n) / 60.0)
		if HitShapes.segment_capsule_fraction(a, b, capsule, HitShapes.CAPSULE_RADIUS + arrow.radius_m,
				HitShapes.CAPSULE_HEIGHT) >= 0.0:
			return true
	return false


func _count_button(rig: Rig, button: int) -> int:
	var count: int = 0
	for input: PlayerInput in rig.inputs:
		if (input.buttons & button) != 0:
			count += 1
	return count


# --- Derribados ---------------------------------------------------------------------------------

func test_it_executes_a_downed_enemy_holding_interact() -> void:
	var rig: Rig = _squire(BotTarget.new(Vector3(0.0, 0.0, -1.0), Vector3.ZERO, true, 42))
	rig.run(100)
	var held: int = _longest_hold(rig, PlayerInput.INTERACT)
	assert_true(held >= CombatCatalog.tables().execute_ticks,
			"mantiene INTERACT lo que dura el remate (%d ticks)" % held)
	assert_eq(_count_button(rig, PlayerInput.PRIMARY), 0, "no le pega: lo remata")
	assert_true(int(rig.brain.get_kit_counts().get(&"execute", 0)) >= 1, "cuenta el remate")
	# De lejos, va hacia él.
	var far: Rig = _squire(BotTarget.new(Vector3(0.0, 0.0, -6.0), Vector3.ZERO, true, 42))
	var input: PlayerInput = far.step()
	assert_eq(input.move, Vector2(0.0, 1.0), "se acerca al derribado")
	assert_false(input.has(PlayerInput.INTERACT), "sin pulsar aún")


func test_it_revives_a_downed_ally_when_no_enemy_is_close() -> void:
	var rig: Rig = _squire(null)
	var ally: Array[Vector3] = [Vector3(0.0, 0.0, -5.0)]
	rig.brain.set_ally_finder(func(_position: Vector3) -> Variant: return ally[0])
	var input: PlayerInput = rig.step()
	assert_eq(input.move, Vector2(0.0, 1.0), "va hacia el aliado derribado")
	assert_near(angle_difference(input.look_yaw, 0.0), 0.0, 1e-3, "mirándolo (hacia -Z)")
	ally[0] = Vector3(0.0, 0.0, -1.0)
	rig.run(200)
	var held: int = _longest_hold(rig, PlayerInput.INTERACT)
	assert_true(held >= CombatCatalog.tables().revive_ticks, "mantiene INTERACT lo que dura levantarlo (%d)" % held)
	assert_true(int(rig.brain.get_kit_counts().get(&"revive", 0)) >= 1, "cuenta el levantamiento")
	# Con un enemigo en pie encima, pelea.
	var busy: Rig = _squire(Vector3(0.0, 0.0, -2.0))
	busy.brain.set_ally_finder(func(_position: Vector3) -> Variant: return Vector3(1.0, 0.0, 0.0))
	busy.run(200)
	assert_eq(int(busy.brain.get_kit_counts().get(&"revive", 0)), 0, "con el enemigo a 2 m no se pone a levantar")


func test_the_kit_is_deterministic_with_the_seed() -> void:
	var first: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 21, Vector3(0.0, 0.0, -14.0))
	var second: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 21, Vector3(0.0, 0.0, -14.0))
	first.run(1500)
	second.run(1500)
	for index: int in first.inputs.size():
		assert_eq(first.inputs[index].encode(), second.inputs[index].encode(), "tick %d" % first.inputs[index].tick)
	assert_eq(first.c.ability_ready, second.c.ability_ready, "y el mismo estado")


func test_load_test_archers_never_swap_to_the_sword_and_can_aim_at_the_sky() -> void:
	var rig: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -3.0))
	rig.brain.kit_ranged_only = true
	rig.run(120)
	assert_eq(rig.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "un arquero puro no saca la espada de cerca")
	assert_eq(int(rig.brain.get_kit_counts().get(&"swap", 0)), 0)
	assert_true(_count_button(rig, PlayerInput.PRIMARY) > 0, "y sigue disparando")
	# Con la espada en la mano vuelve al arco aunque el enemigo esté cerca.
	var melee: Rig = _rig(&"sword_shield", &"bow", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -3.0))
	melee.brain.kit_ranged_only = true
	melee.run(60)
	assert_eq(melee.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "vuelve al arco")
	# Al cielo: la misma puntería, más alta.
	var plain: Rig = _rig(&"bow", &"", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -20.0))
	var sky: Rig = _rig(&"bow", &"", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -20.0))
	sky.brain.kit_aim_raise = 0.8
	var a: PlayerInput = plain.step()
	var b: PlayerInput = sky.step()
	assert_near(b.look_pitch - a.look_pitch, 0.8, 0.01, "sube la puntería lo que se pide")
