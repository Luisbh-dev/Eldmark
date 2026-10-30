extends TestCase
## El kit de la fase 4 (H5; docs/habilidades.md, sección 7.1) en el patrón de asedio de F6b ([constant
## BotBrain.Pattern.SIEGE]; docs/fuerte.md, secciones 7 y 8.3), sin red ni física: un punto que se mueve donde dicen
## las entradas, con una máquina de acciones que avanza con ellas ([KitWalker]), el fuerte del Vado Gris de verdad y sus
## rutas. Se comprueba lo que pide la integración de las dos ramas: el bot de asedio pelea con el kit en el paso 1 de
## su plan, también con el PNJ defensor (que sigue yendo antes que un jugador más cercano, y al que apunta el arco con su
## velocidad); con el arco en la mano no deja de disparar por la regla de las persecuciones (la espada sí la sigue); en
## la pasarela el arquero no da pasos de lado; no levanta a nadie (sigue su plan), y es determinista.

const V: int = NetProtocol.Realm.VARDHEIM
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Puerta y círculo del Vado Gris (el fuerte está en el origen; norte = -Z), como en test_bot_brain_siege.
const GATE: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, 0.0, 0.0)
const CIRCLE_RADIUS: float = 5.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0
const START_TICK: int = 1000

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## Un punto que obedece a las entradas (sin colisiones; con [member blocked] no se mueve) y lleva el estado de combate
## que lee el kit: una máquina de acciones que avanza con esas mismas entradas.
class KitWalker:
	extends RefCounted

	var c: CombatState
	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var blocked: bool = false
	var tick: int = START_TICK
	var inputs: Array[PlayerInput] = []
	## Cada pulsación (flanco) de una habilidad o un consumible: (tick, casilla, estado de la casilla en ese tick).
	var presses: Array[Vector3i] = []


	func _init(state: CombatState, start: Vector3) -> void:
		c = state
		position = start


	func step(brain: BotBrain) -> PlayerInput:
		var t: int = tick + 1
		var input: PlayerInput = brain.next_input(t, position, yaw).quantized()
		input.tick = t
		var previous: int = inputs[inputs.size() - 1].buttons if not inputs.is_empty() else 0
		for slot: int in 5:
			var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3,
					PlayerInput.CONSUMABLE_1, PlayerInput.CONSUMABLE_2][slot]
			if (input.buttons & button) != 0 and (previous & button) == 0:
				presses.append(Vector3i(t, slot, ActionMachine.ability_status(c, slot, t)))
		ActionMachine.step(c, input, true)
		yaw = input.look_yaw
		if not blocked and input.move.length() > 0.0:
			var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var speed: float = SPRINT_SPEED if input.has(PlayerInput.SPRINT) else WALK_SPEED
			position += (forward * input.move.y + right * input.move.x) * speed / TICKS_PER_SECOND
		tick = t
		inputs.append(input)
		return input


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	_view = SiegeView.new()
	_view.fortress_id = &"vado_gris_fort"
	_view.set_places(GATE, CIRCLE, CIRCLE_RADIUS)
	# Un fuerte neutral con el capitán vivo (el círculo no está activo: los defensores van primero) y la puerta rota.
	_view.known = true
	_view.owner = 0
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 0
	_view.gate_max = 9000


func _squire_state() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"), 0,
			CombatState.pack_charges(3, 2))


func _marksman_state() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"bow"),
			CombatCatalog.weapon_id(&"sword_shield"), CombatState.pack_charges(2, 3))


## Un cerebro de asedio de Vardheim sin el papel de la pasarela que lee el estado de [param walker].
func _brain(walker: KitWalker, rng_seed: int) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, V)
	brain.set_walkway_role(false)
	# El cierre guarda el estado, no el KitWalker: sin ciclos de referencias.
	var state: CombatState = walker.c
	brain.set_combat_source(func() -> CombatState: return state)
	return brain


# El yaw (convención de PlayerInput: 0 mira hacia -Z) que mira de [param from] a [param to].
func _yaw_to(from: Vector3, to: Vector3) -> float:
	return fposmod(atan2(-(to.x - from.x), -(to.z - from.z)), TAU)


func _angle_gap(a: float, b: float) -> float:
	return absf(angle_difference(a, b))


# --- Pruebas ----------------------------------------------------------------------------------

func test_against_the_defender_npc_the_squire_fights_with_its_kit() -> void:
	var walker := KitWalker.new(_squire_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
	var brain: BotBrain = _brain(walker, 41)
	var npc: Vector3 = walker.position + Vector3(1.6, 0.0, 0.0)
	var player: Vector3 = walker.position + Vector3(0.0, 0.0, 1.2)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(player))
	brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(npc))
	var fighting: int = 0
	for _i: int in 3000:
		walker.step(brain)
		fighting += 1 if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	var counts: Dictionary[StringName, int] = brain.get_kit_counts()
	print("[asedio con kit] escudero contra el PNJ defensor, 3000 ticks: %s" % [counts])
	assert_eq(fighting, 3000, "pelea todo el rato (el paso 1 de su plan)")
	assert_true(_angle_gap(walker.yaw, _yaw_to(walker.position, npc)) < 0.3,
			"con el PNJ defensor aunque el jugador esté más cerca (yaw %.2f)" % walker.yaw)
	assert_true(counts.get(&"ability_0", 0) + counts.get(&"ability_2", 0) >= 2,
			"con las habilidades del escudero (%s)" % [counts])
	for press: Vector3i in walker.presses:
		assert_eq(press.z, ActionMachine.AbilityStatus.READY,
				"solo pulsa una casilla lista (tick %d, casilla %d)" % [press.x, press.y])


func test_the_bow_aims_at_the_defender_npc_leading_it_by_its_velocity() -> void:
	# El defensor, a 10 m al este y corriendo hacia el sur; un jugador a 6 m al oeste. El arco apunta al defensor (el blanco
	# de la pelea) y por delante de él: con su velocidad, más al sur que sin ella.
	var yaws: Array[float] = []
	var direct: float = 0.0
	for velocity: Vector3 in [Vector3.ZERO, Vector3(0.0, 0.0, 4.0)]:
		var walker := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
		walker.blocked = true
		var brain: BotBrain = _brain(walker, 42)
		var npc: Vector3 = walker.position + Vector3(10.0, 0.0, 0.0)
		var player: Vector3 = walker.position + Vector3(-6.0, 0.0, 0.0)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(player))
		brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(npc, velocity))
		# Un tick en que acaba de mirar dónde está (cada COMBAT_RETARGET_TICKS): sin extrapolar la posición.
		for _i: int in 1 + BotBrain.COMBAT_RETARGET_TICKS * 3:
			walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
		yaws.append(walker.yaw)
		direct = _yaw_to(walker.position, npc)
		assert_true(_angle_gap(walker.yaw, direct) < 0.4,
				"al defensor (yaw %.3f, directo %.3f) y no al jugador" % [walker.yaw, direct])
	# Hacia +Z el yaw baja (el este es 3π/2 y el sur, π): adelantarse al sur es un yaw menor.
	assert_true(yaws[1] < yaws[0] - 0.02,
			"con la velocidad del defensor apunta por delante de él (%.3f frente a %.3f)" % [yaws[1], yaws[0]])


func test_with_the_bow_in_hand_it_keeps_shooting_instead_of_giving_up_the_chase() -> void:
	# F6b deja una persecución que no le acerca en SIEGE_STUCK_TICKS; el arquero no persigue (todo SIEGE_FIGHT_RANGE es
	# distancia de tiro), así que sigue disparando. Con la espada, la regla se aplica igual que sin kit.
	var archer := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-1.0, 0.0, 0.0))
	archer.blocked = true
	var archer_brain: BotBrain = _brain(archer, 35)
	var foe: Vector3 = archer.position + Vector3(0.0, 0.0, -10.0)
	archer_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var fighting: int = 0
	for _i: int in 900:
		archer.step(archer_brain)
		fighting += 1 if archer_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	var counts: Dictionary[StringName, int] = archer_brain.get_kit_counts()
	assert_eq(fighting, 900, "no deja de pelear con el de 10 m")
	assert_true(counts.get(&"quick", 0) + counts.get(&"drawn", 0) >= 5, "y le dispara (%s)" % [counts])

	var squire := KitWalker.new(_squire_state(), CIRCLE + Vector3(-1.0, 0.0, 0.0))
	squire.blocked = true
	var squire_brain: BotBrain = _brain(squire, 35)
	squire_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var gave_up: int = -1
	for i: int in 600:
		squire.step(squire_brain)
		if squire_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT:
			gave_up = i + 1
			break
	assert_true(gave_up >= BotBrain.SIEGE_STUCK_TICKS
			and gave_up <= BotBrain.SIEGE_STUCK_TICKS + 2 * BotBrain.COMBAT_RETARGET_TICKS,
			"con la espada deja la persecución a los %d ticks sin acercarse (%d)" % [BotBrain.SIEGE_STUCK_TICKS, gave_up])


func test_an_archer_on_the_walkway_never_steps_sideways() -> void:
	# Un guardia de la pasarela (el fuerte es suyo) con el arco y un enemigo que viene por ella a 10 m: guarda la distancia
	# sin los pasos de lado del arquero (sin barandilla por dentro, se caería al patio).
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var walker := KitWalker.new(_marksman_state(), Vector3(-18.77, _routes.walkway_height, 0.0))
	walker.blocked = true
	var brain := BotBrain.new(43, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, V)
	brain.set_walkway_role(true)
	var state: CombatState = walker.c
	brain.set_combat_source(func() -> CombatState: return state)
	var foe := Vector3(-18.77, _routes.walkway_height, 10.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	assert_true(brain.is_on_walkway(walker.position), "está en la pasarela")
	var sideways: int = 0
	for _i: int in 900:
		var input: PlayerInput = walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
		sideways += 1 if absf(input.move.x) > 0.01 else 0
	var counts: Dictionary[StringName, int] = brain.get_kit_counts()
	assert_eq(sideways, 0, "ningún paso de lado en la pasarela")
	assert_true(counts.get(&"quick", 0) + counts.get(&"drawn", 0) >= 5, "y dispara (%s)" % [counts])
	# En el patio (no en la pasarela), el mismo arquero sí se mueve de lado entre disparo y disparo.
	var below := KitWalker.new(_marksman_state(), CIRCLE)
	below.blocked = true
	var other: BotBrain = _brain(below, 43)
	var near := CIRCLE + Vector3(0.0, 0.0, 10.0)
	other.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(near))
	var strafes: int = 0
	for _i: int in 900:
		strafes += 1 if absf(below.step(other).move.x) > 0.01 else 0
	assert_true(strafes > 0, "en el patio, de lado (%d ticks)" % strafes)


func test_fighting_on_the_walkway_it_looks_along_it_and_never_dashes() -> void:
	# Con el enemigo casi al lado (0,37 m hacia el patio y 0,1 a lo largo), mirarle a él era mirar al patio: la esquiva
	# «hacia atrás» le tiraba de la pasarela. Mira por el eje hacia él y no usa la embestida (avanza 6 m y empuja), con el
	# kit y sin él.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	for with_kit: bool in [true, false]:
		var walker := KitWalker.new(_squire_state(), Vector3(-18.77, _routes.walkway_height, 0.0))
		walker.blocked = true
		var brain := BotBrain.new(46, BotBrain.Pattern.SIEGE)
		brain.set_siege(_view, _routes, V)
		brain.set_walkway_role(true)
		if with_kit:
			var state: CombatState = walker.c
			brain.set_combat_source(func() -> CombatState: return state)
		var foe := Vector3(-18.4, _routes.walkway_height, 0.1)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
		var across: int = 0
		var dodges: int = 0
		for _i: int in 1800:
			var input: PlayerInput = walker.step(brain)
			assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
			# El eje es la pared de la puerta (x = -18,77): mirar por él es mirar hacia ±Z.
			across += 1 if absf(sin(input.look_yaw)) > 0.05 else 0
			dodges += 1 if input.has(PlayerInput.DODGE) else 0
		var counts: Dictionary[StringName, int] = brain.get_kit_counts()
		assert_eq(across, 0, "kit %s: siempre mira por el eje" % with_kit)
		assert_true(dodges > 0, "kit %s: alguna esquiva hubo (%d), por el eje" % [with_kit, dodges])
		assert_false(counts.has(&"ability_1"), "kit %s: sin la embestida en la pasarela (%s)" % [with_kit, counts])
		if with_kit:
			assert_true(counts.get(&"ability_0", 0) + counts.get(&"ability_2", 0) > 0,
					"con el golpe de escudo y el muro, que no se mueven (%s)" % [counts])
	# A 5 m por el eje, la distancia de la embestida: en el patio la usa; en la pasarela, no.
	for up: bool in [true, false]:
		var height: float = _routes.walkway_height if up else 0.0
		var walker := KitWalker.new(_squire_state(), Vector3(-18.77 if up else -14.0, height, 0.0))
		walker.blocked = true
		var brain := BotBrain.new(47, BotBrain.Pattern.SIEGE)
		brain.set_siege(_view, _routes, V)
		brain.set_walkway_role(up)
		var state: CombatState = walker.c
		brain.set_combat_source(func() -> CombatState: return state)
		var foe := walker.position + Vector3(0.0, 0.0, 5.0)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
		for _i: int in 1800:
			walker.step(brain)
		var rushes: int = brain.get_kit_counts().get(&"ability_1", 0)
		if up:
			assert_eq(rushes, 0, "en la pasarela, ninguna embestida")
		else:
			assert_true(rushes > 0, "en el patio, la embestida (%d)" % rushes)


func test_a_siege_bot_follows_its_plan_and_does_not_revive_allies() -> void:
	# H5: los de asedio usan el kit al pelear pero no levantan a nadie (siguen su plan). Un aliado derribado a 2 m y ningún
	# enemigo: sigue hacia el círculo sin pulsar INTERACT.
	var walker := KitWalker.new(_squire_state(), CIRCLE + Vector3(-4.0, 0.0, 0.0))
	var brain: BotBrain = _brain(walker, 44)
	var ally: Vector3 = walker.position + Vector3(0.0, 0.0, 2.0)
	brain.set_ally_finder(func(_position: Vector3) -> Variant: return ally)
	for _i: int in 300:
		var input: PlayerInput = walker.step(brain)
		assert_false(input.has(PlayerInput.INTERACT), "no levanta al aliado")
		assert_true(brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "no hay nadie con quien pelear")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "está en el círculo")
	assert_false(brain.get_kit_counts().has(&"revive"))


func test_the_kit_in_the_siege_is_deterministic() -> void:
	var traces: Array[PackedByteArray] = []
	for _run: int in 2:
		var walker := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
		var brain: BotBrain = _brain(walker, 45)
		var npc: Vector3 = walker.position + Vector3(4.0, 0.0, 0.0)
		var player: Vector3 = walker.position + Vector3(0.0, 0.0, 8.0)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(player))
		brain.set_defender_finder(func(position: Vector3) -> Variant:
			return BotTarget.new(npc, Vector3(0.0, 0.0, 2.0)) if position.x < CIRCLE.x + 2.0 else null)
		var trace := PackedByteArray()
		for _i: int in 1500:
			trace.append_array(walker.step(brain).encode())
		traces.append(trace)
	assert_eq(traces[0], traces[1], "mismas entradas con la misma semilla y el mismo mundo")
