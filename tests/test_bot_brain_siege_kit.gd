extends TestCase
## El kit de la fase 4 (H5; docs/habilidades.md, sección 7.1) en el patrón de asedio de F6b ([constant
## BotBrain.Pattern.SIEGE]; docs/fuerte.md, secciones 7 y 8.3), sin red ni física: un punto que se mueve donde dicen
## las entradas, con una máquina de acciones que avanza con ellas ([KitWalker]), el fuerte del Vado Gris de verdad y sus
## rutas. Se comprueba lo que pide la integración de las dos ramas: el bot de asedio pelea con el kit en el paso 1 de
## su plan, también con el PNJ defensor (que sigue yendo antes que un jugador más cercano, y al que apunta el arco con su
## velocidad); con el arco en la mano no deja de disparar por la regla de las persecuciones (la espada sí la sigue); en
## la pasarela el arquero no da pasos de lado; no levanta a nadie (sigue su plan), y es determinista.
## [br]Y lo que añade la revisión de la integración (docs/fuerte.md 8.3): en la pasarela mira al enemigo (la espada le
## llega aunque esté de través) y mueve por el eje; el arco solo tira a tiro (ni a través de una puerta cerrada, ni la
## suya, ni de la empalizada; con la puerta rota, por el vano; y lo que diga la línea de tiro), hasta
## [constant BotBrain.SIEGE_BOW_FIGHT_RANGE], saca el arco con la espada en la mano, tira a otro nivel (el filtro de
## nivel es del cuerpo a cuerpo), ir a rematar lleva la regla de las persecuciones y la puerta se golpea con la espada.
## La física de verdad, en [code]test_siege_archers[/code].

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
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


# Hacia dónde mueve [param input] en el mundo (la simulación mueve relativo a su look_yaw).
func _world_move(input: PlayerInput) -> Vector3:
	var forward := Vector3(-sin(input.look_yaw), 0.0, -cos(input.look_yaw))
	var right := Vector3(cos(input.look_yaw), 0.0, -sin(input.look_yaw))
	return forward * input.move.y + right * input.move.x


# Disparos del arco que ha decidido el kit (rápidos, tensados y habilidades de disparo).
func _shots(brain: BotBrain) -> int:
	var counts: Dictionary[StringName, int] = brain.get_kit_counts()
	return counts.get(&"quick", 0) + counts.get(&"drawn", 0)


# La plantilla del tirador con la espada en la mano (como tras cambiar de arma) y el arco a la espalda.
func _marksman_sword_state() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"),
			CombatCatalog.weapon_id(&"bow"), CombatState.pack_charges(2, 3))


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


func test_fighting_on_the_walkway_it_faces_the_foe_moves_along_the_axis_and_never_dashes() -> void:
	# Con el enemigo casi al lado (0,37 m hacia el patio y 0,1 a lo largo), una esquiva «hacia atrás» desde él le tiraba de
	# la pasarela. La integración le hacía mirar por el eje, y entonces el de al lado era intocable para él (revisión de la
	# integración, docs/fuerte.md 8.3): mira al enemigo, pero lo que mueve (acercarse, la esquiva) va por el eje, y no usa
	# la embestida (avanza 6 m y empuja), con el kit y sin él.
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
		var away: int = 0
		var across: int = 0
		var dodges: int = 0
		var side_dodges: int = 0
		for _i: int in 1800:
			var input: PlayerInput = walker.step(brain)
			assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
			away += 1 if _angle_gap(input.look_yaw, _yaw_to(walker.position, foe)) > 0.1 else 0
			# El eje es la pared de la puerta (x = -18,77): por el eje es hacia ±Z en el mundo.
			var world: Vector3 = _world_move(input)
			across += 1 if world.length() > 0.01 and absf(world.x) > 0.1 * world.length() else 0
			if input.has(PlayerInput.DODGE):
				dodges += 1
				var dodge_yaw: float = input.look_yaw + atan2(-input.move.x, input.move.y)
				side_dodges += 1 if absf(sin(dodge_yaw)) > 0.1 else 0
		var counts: Dictionary[StringName, int] = brain.get_kit_counts()
		assert_eq(away, 0, "kit %s: siempre mira al enemigo" % with_kit)
		assert_eq(across, 0, "kit %s: lo que mueve va por el eje" % with_kit)
		assert_true(dodges > 0, "kit %s: alguna esquiva hubo (%d)" % [with_kit, dodges])
		assert_eq(side_dodges, 0, "kit %s: y por el eje, no hacia el patio" % with_kit)
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


func test_on_the_walkway_its_sword_reaches_a_foe_right_beside_it() -> void:
	# La sonda de la revisión de la integración: mirando por el eje, el enemigo pegado de través (0,9 o 1,2 m de lado y
	# casi nada a lo largo) quedaba fuera del sector de la espada (100°). Mirándole, le llega, con el kit y sin él.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var sword: AttackTicks = CombatCatalog.attack(
			CombatCatalog.weapon(CombatCatalog.weapon_id(&"sword_shield")).light_ids[0])
	for with_kit: bool in [false, true]:
		for lateral: float in [0.6, 0.9, 1.2]:
			for along: float in [0.0, 0.2, 0.5]:
				var brain := BotBrain.new(43, BotBrain.Pattern.SIEGE)
				brain.set_siege(_view, _routes, V)
				brain.set_walkway_role(true)
				var me: Vector3 = brain.get_walkway_post() as Vector3
				var offset: float = _routes.walkway_offset(Vector2(me.x, me.z))
				var a: Vector2 = _routes.walkway_point(offset - 0.25)
				var b: Vector2 = _routes.walkway_point(offset + 0.25)
				var tangent := Vector3(b.x - a.x, 0.0, b.y - a.y).normalized()
				var normal := Vector3(-tangent.z, 0.0, tangent.x)
				var foe: Vector3 = me + tangent * along + normal * lateral
				var state: CombatState = _squire_state()
				if with_kit:
					brain.set_combat_source(func() -> CombatState: return state)
				brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
				var yaw: float = atan2(-tangent.x, -tangent.z)
				for t: int in 40:
					yaw = brain.next_input(START_TICK + t, me, yaw).look_yaw
				assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
				assert_true(HitShapes.sector_hits_capsule(me, yaw, sword.shape, foe, HitShapes.CAPSULE_RADIUS,
						HitShapes.CAPSULE_HEIGHT), "kit %s, %.1f m de lado y %.1f a lo largo: la espada le llega" % [
						with_kit, lateral, along])


func test_the_archer_never_shoots_through_a_closed_gate_not_even_its_own() -> void:
	# Revisión de la integración (docs/fuerte.md 8.3): el dueño veía «alcanzables» a los de fuera (su puerta no le cierra el
	# paso), pero su cuerpo de vista para las flechas en los dos sentidos: 70 de 70 flechas a su propia puerta. Con la
	# puerta entera nadie tira de dentro afuera ni de fuera adentro; rota, solo por el vano.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var owner := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
	owner.blocked = true
	var owner_brain: BotBrain = _brain(owner, 50)
	var at_gate := GATE + Vector3(-2.3, 0.0, 0.0)
	owner_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(at_gate))
	var outside := KitWalker.new(_marksman_state(), GATE + Vector3(-8.0, 0.0, 0.0))
	outside.blocked = true
	var outside_brain := BotBrain.new(51, BotBrain.Pattern.SIEGE)
	outside_brain.set_siege(_view, _routes, S)
	outside_brain.set_walkway_role(false)
	var outside_state: CombatState = outside.c
	outside_brain.set_combat_source(func() -> CombatState: return outside_state)
	var in_yard := CIRCLE + Vector3(-3.0, 0.0, 0.0)
	outside_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(in_yard))
	for _i: int in 600:
		owner.step(owner_brain)
		outside.step(outside_brain)
		assert_true(owner_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "el dueño no tira a su puerta")
		assert_true(outside_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "ni el de fuera a la puerta cerrada")
	assert_eq(_shots(owner_brain) + _shots(outside_brain), 0)
	# Rota: los dos en el eje de la puerta, por el vano, se tiran.
	_view.gate_health = 0
	var dueling: int = 0
	for _i: int in 600:
		owner.step(owner_brain)
		dueling += 1 if owner_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	assert_eq(dueling, 600, "con la puerta rota, el dueño tira por el vano al de la puerta")
	assert_true(_shots(owner_brain) >= 5, "y le dispara (%s)" % [owner_brain.get_kit_counts()])


func test_with_the_gate_broken_it_only_shoots_through_the_opening() -> void:
	# Revisión de la integración: con la puerta rota, un blanco a menos de 12 m detrás de la empalizada parecía alcanzable
	# y el arquero se quedaba tirando a la madera (52 de 80 flechas al mundo; dos de cuatro no entraban en 30 s). Si la
	# línea no pasa por el vano, sigue su plan: entra en el fuerte.
	_view.enclosure_size = Vector2(40.0, 40.0)
	var walker := KitWalker.new(_marksman_state(), GATE + Vector3(-4.0, 0.0, 7.0))
	var brain: BotBrain = _brain(walker, 52)
	var npc := GATE + Vector3(6.0, 0.0, 8.0)
	brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(npc))
	var first_inside: int = -1
	for i: int in 900:
		walker.step(brain)
		if first_inside < 0 and _view.is_inside_enclosure(walker.position, 0.5) == 1:
			first_inside = i
		if i < 60:
			assert_true(brain.get_siege_task() != BotBrain.SiegeTask.FIGHT,
					"delante de la empalizada, sin tiro al PNJ de dentro (tick %d, %s)" % [i, walker.position])
	assert_true(first_inside >= 0, "entra en el fuerte por la puerta (%s)" % walker.position)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "y dentro le tira")
	assert_true(_shots(brain) > 0, "(%s)" % [brain.get_kit_counts()])
	# En el eje de la puerta, de fuera adentro por el vano, sí le tira.
	var aligned := KitWalker.new(_marksman_state(), GATE + Vector3(-8.0, 0.0, 0.5))
	aligned.blocked = true
	var aligned_brain: BotBrain = _brain(aligned, 53)
	var through := GATE + Vector3(6.0, 0.0, 0.0)
	aligned_brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(through))
	for _i: int in 300:
		aligned.step(aligned_brain)
		assert_eq(aligned_brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "por el vano tiene tiro")
	assert_true(_shots(aligned_brain) > 0)


func test_the_line_of_sight_decides_the_shot_and_is_asked_once_per_search() -> void:
	# En el patio y a 10 m, lo que diga la línea de tiro (el servidor y --bot: el rayo de su mundo).
	var clear: Array[bool] = [false]
	var asked: Array[int] = [0]
	var walker := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-1.0, 0.0, 0.0))
	walker.blocked = true
	var brain: BotBrain = _brain(walker, 54)
	brain.set_line_of_sight(func(_from: Vector3, _to: Vector3, _left: bool) -> bool:
		asked[0] += 1
		return clear[0])
	assert_true(brain.has_line_of_sight())
	var foe: Vector3 = walker.position + Vector3(0.0, 0.0, -10.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	for _i: int in 300:
		walker.step(brain)
		assert_true(brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "sin línea de tiro no le tira")
	assert_eq(_shots(brain), 0)
	assert_true(asked[0] <= 300 / BotBrain.COMBAT_RETARGET_TICKS + 1,
			"una pregunta por búsqueda del blanco (%d en 300 ticks)" % asked[0])
	clear[0] = true
	var fighting: int = 0
	for _i: int in 300:
		walker.step(brain)
		fighting += 1 if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	assert_true(fighting >= 300 - BotBrain.COMBAT_RETARGET_TICKS, "con ella, sí (%d)" % fighting)
	assert_true(_shots(brain) > 0)


func test_the_bow_fights_further_than_the_sword() -> void:
	# A 16 m: el arquero le tira (SIEGE_BOW_FIGHT_RANGE); el escudero sigue con su plan (SIEGE_FIGHT_RANGE).
	var archer := KitWalker.new(_marksman_state(), CIRCLE)
	archer.blocked = true
	var archer_brain: BotBrain = _brain(archer, 55)
	var foe := CIRCLE + Vector3(0.0, 0.0, 16.0)
	archer_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var squire := KitWalker.new(_squire_state(), CIRCLE)
	squire.blocked = true
	var squire_brain: BotBrain = _brain(squire, 55)
	squire_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var archer_fights: int = 0
	var squire_fights: int = 0
	for _i: int in 600:
		archer.step(archer_brain)
		squire.step(squire_brain)
		archer_fights += 1 if archer_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
		squire_fights += 1 if squire_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	assert_eq(archer_fights, 600, "el arquero tira a 16 m")
	assert_true(_shots(archer_brain) >= 5, "(%s)" % [archer_brain.get_kit_counts()])
	assert_eq(squire_fights, 0, "el escudero no pelea a 16 m")


func test_with_the_sword_in_hand_it_draws_the_bow_for_a_far_target_without_closing_in() -> void:
	# El tirador que sacó la espada (de cerca, o para la puerta) vuelve al arco con un blanco a tiro y lejos: a 15 m.
	var walker := KitWalker.new(_marksman_sword_state(), CIRCLE)
	var brain: BotBrain = _brain(walker, 56)
	var foe := CIRCLE + Vector3(0.0, 0.0, 15.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var swapped_at: int = -1
	for i: int in 600:
		walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
		if swapped_at < 0:
			assert_true(walker.position.distance_to(CIRCLE) < 0.01, "sacando el arco no se acerca con la espada")
			if walker.c.weapon_id == bow:
				swapped_at = i
	assert_true(swapped_at >= 0 and swapped_at < 120, "saca el arco (tick %d)" % swapped_at)
	assert_true(_shots(brain) > 0, "y tira (%s)" % [brain.get_kit_counts()])


func test_the_level_filter_is_for_the_sword_the_bow_shoots_across_levels() -> void:
	# GUE-45: dentro del recinto, quien está a otro nivel no se alcanza con la espada. Con el arco sí, si hay tiro: un
	# guardia de la pasarela tira al patio, y uno del patio con la espada en la mano saca el arco para el de la pasarela.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var guard := KitWalker.new(_marksman_state(), Vector3(-18.77, _routes.walkway_height, 0.0))
	guard.blocked = true
	var guard_brain := BotBrain.new(57, BotBrain.Pattern.SIEGE)
	guard_brain.set_siege(_view, _routes, V)
	guard_brain.set_walkway_role(true)
	var guard_state: CombatState = guard.c
	guard_brain.set_combat_source(func() -> CombatState: return guard_state)
	var below := Vector3(-12.0, 0.0, 3.0)
	guard_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(below))
	var moved: int = 0
	for _i: int in 600:
		var input: PlayerInput = guard.step(guard_brain)
		assert_eq(guard_brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "el guardia tira al del patio")
		moved += 1 if input.move.length() > 0.01 else 0
	assert_true(_shots(guard_brain) >= 5, "(%s)" % [guard_brain.get_kit_counts()])
	assert_eq(moved, 0, "sin moverse en la pasarela")
	_view.owner = S
	var yard := KitWalker.new(_marksman_sword_state(), Vector3(-12.0, 0.0, 3.0))
	yard.blocked = true
	var yard_brain: BotBrain = _brain(yard, 58)
	var up := Vector3(-18.77, _routes.walkway_height, 1.0)
	yard_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(up))
	for _i: int in 600:
		yard.step(yard_brain)
		assert_eq(yard_brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "el del patio le tira al de la pasarela")
	assert_eq(yard.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "con el arco: la espada no le llega")
	assert_true(_shots(yard_brain) > 0, "(%s)" % [yard_brain.get_kit_counts()])
	# Sin el kit, el mismo de la pasarela no es un blanco desde el patio (GUE-45, como siempre).
	var plain := KitWalker.new(_squire_state(), Vector3(-12.0, 0.0, 3.0))
	var plain_brain := BotBrain.new(58, BotBrain.Pattern.SIEGE)
	plain_brain.set_siege(_view, _routes, V)
	plain_brain.set_walkway_role(false)
	plain_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(up))
	plain.step(plain_brain)
	assert_true(plain_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "sin el arco no es un blanco")


func test_going_to_finish_a_downed_foe_it_gives_up_a_chase_that_does_not_close_in() -> void:
	# Revisión de la integración: ir a rematar con el arco en la mano no tenía ninguna regla para rendirse, y se quedaba
	# empujando la empalizada hasta que el derribado se desangraba. Acercarse es perseguir: la regla de F6b.
	_view.enclosure_size = Vector2(40.0, 40.0)
	var walker := KitWalker.new(_marksman_state(), Vector3(-10.0, 0.0, 23.0))
	walker.blocked = true
	var brain: BotBrain = _brain(walker, 59)
	var downed := Vector3(-10.0, 0.0, 17.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(downed, Vector3.ZERO, true))
	var gave_up: int = -1
	for i: int in 600:
		walker.step(brain)
		if brain.get_siege_task() != BotBrain.SiegeTask.FIGHT:
			gave_up = i + 1
			break
	assert_true(gave_up >= BotBrain.SIEGE_STUCK_TICKS
			and gave_up <= BotBrain.SIEGE_STUCK_TICKS + 2 * BotBrain.COMBAT_RETARGET_TICKS,
			"deja de ir a rematarlo a los %d ticks sin acercarse (%d)" % [BotBrain.SIEGE_STUCK_TICKS, gave_up])


func test_a_marksman_swaps_to_the_sword_to_hit_the_gate() -> void:
	# Revisión de la integración: a flechazos, 4 tiradores le quitaban a la puerta unas 2,6 veces menos que 4 escuderos.
	# El tirador saca la espada para golpearla; el arquero puro de las pruebas de carga (kit_ranged_only), no.
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	for ranged_only: bool in [false, true]:
		var walker := KitWalker.new(_marksman_state(), GATE + Vector3(-6.0, 0.0, 0.0))
		var brain: BotBrain = _brain(walker, 60)
		brain.kit_ranged_only = ranged_only
		var presses: int = 0
		var assaulting: int = 0
		for _i: int in 900:
			var input: PlayerInput = walker.step(brain)
			if brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT:
				assaulting += 1
				presses += 1 if input.has(PlayerInput.PRIMARY) else 0
		assert_true(assaulting > 600, "llega a la puerta y la asalta (%d ticks)" % assaulting)
		assert_true(presses > 0, "golpea la puerta")
		if ranged_only:
			assert_true(walker.c.weapon_id != sword, "el arquero puro no cambia de arma")
		else:
			assert_eq(walker.c.weapon_id, sword, "con la espada")
			assert_eq(brain.get_kit_counts().get(&"swap", 0), 1, "un cambio de arma")
