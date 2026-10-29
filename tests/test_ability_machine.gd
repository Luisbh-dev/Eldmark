extends TestCase
## Pruebas de las habilidades en la máquina de acciones ([ActionMachine] y [AbilityRules];
## docs/habilidades.md, secciones 3.3 a 3.6) sin física, con [MachineDriver]: el flanco, el
## compromiso y la reutilización, las canalizaciones (soltar, moverse, el tope y los ejemplos de la
## sección 3.3), las prioridades, el búfer, las entradas sustituidas, las consultas y lo que impone el
## servidor (derribado, levantar, rematar, interrupción).
## [br][br]
## Datos de la espada y el escudo (ticks): golpe de escudo 18 + 6 + 24 (reutilización 720),
## embestida 9 + 24 + 21 con avance de 6 m en [9, 33) (960), muro 12 + hasta 360 canalizado (1080,
## esquiva desde 12). Los ids se piden por nombre.

const Action = CombatState.Action
const PRIMARY: int = PlayerInput.PRIMARY
const DODGE: int = PlayerInput.DODGE
const BLOCK: int = PlayerInput.BLOCK
const ABILITY_1: int = PlayerInput.ABILITY_1
const ABILITY_2: int = PlayerInput.ABILITY_2
const ABILITY_3: int = PlayerInput.ABILITY_3
const SWAP: int = PlayerInput.SWAP_WEAPON
const CONSUMABLE_1: int = PlayerInput.CONSUMABLE_1
const INTERACT: int = PlayerInput.INTERACT

## Recursos cambiados por una prueba: [recurso, propiedad, valor original].
var _mutations: Array[Array] = []


func after_each() -> void:
	if _mutations.is_empty():
		return
	for i: int in range(_mutations.size() - 1, -1, -1):
		var entry: Array = _mutations[i]
		(entry[0] as Resource).set(entry[1], entry[2])
	_mutations.clear()
	CombatCatalog.reload()


# --- Flanco, compromiso y reutilización ------------------------------------------------------

func test_the_edge_starts_the_ability_and_the_commit_sets_its_cooldown() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq([bash.cast_ticks, bash.active_ticks, bash.recovery_ticks, bash.cooldown_ticks],
			[18, 6, 24, 720], "golpe de escudo: 18 + 6 + 24, 12 s")
	var d := _sword_driver()
	d.hold(0, 3)
	d.c.combo_step = 2
	var p: int = d.tick + 1
	var first: ActionMachine.Output = d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "el flanco de ABILITY_1 empieza la habilidad")
	assert_eq(d.c.action_id, bash.id, "la de la ranura 1")
	assert_eq(d.c.action_tick, p, "en el tick del flanco")
	assert_eq(d.c.combo_step, 0, "el combo vuelve a empezar")
	assert_true(first.snap_yaw, "en el primer tick el yaw salta a la cámara")
	assert_true(first.scaled_movement, "movimiento escalado")
	assert_near(first.move_scale, 0.2, 1e-6, "×0,2")
	assert_near(first.lunge_speed, 1.0, 1e-6, "avance de 1 m/s")
	assert_near(first.turn_rate, 6.0, 1e-6, "giro 6")
	assert_false(first.allow_jump or first.allow_sprint, "sin salto ni esprint")
	assert_eq(d.c.ability_ready[0], 0, "la reutilización se fija en el compromiso, no al empezar")
	var expected_ready: int = p + 18 + 720
	for rel: int in range(1, 48):
		var out: ActionMachine.Output = d.step(ABILITY_1)
		var tick: int = p + rel
		assert_eq(d.c.action, Action.ABILITY, "rel %d: mantener el botón no la repite ni la corta" % rel)
		var phase: int = ActionMachine.phase(d.c, tick)
		if rel < 18:
			assert_eq(phase, ActionMachine.PHASE_WINDUP, "rel %d: lanzamiento" % rel)
			assert_eq(d.c.ability_ready[0], 0, "rel %d: aún sin reutilización" % rel)
			assert_near(out.lunge_speed, 1.0, 1e-6, "rel %d: avanza en el lanzamiento" % rel)
		elif rel < 24:
			assert_eq(phase, ActionMachine.PHASE_ACTIVE, "rel %d: activo" % rel)
			assert_eq(d.c.ability_ready[0], expected_ready, "rel %d: fijada en el compromiso" % rel)
		else:
			assert_eq(phase, ActionMachine.PHASE_RECOVERY, "rel %d: recuperación" % rel)
			assert_eq(out.turn_rate, 0.0, "rel %d: sin giro en la recuperación" % rel)
			assert_eq(out.lunge_speed, 0.0, "rel %d: ni avance" % rel)
		assert_eq(ActionMachine.is_commit_tick(d.c, tick), rel == 18, "rel %d: compromiso en 18" % rel)
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.NONE, "acaba a los 48 ticks")
	assert_eq(d.c.ability_ready[0], expected_ready, "la reutilización sigue")
	assert_eq(d.c.ability_ready.slice(1), PackedInt64Array([0, 0, 0, 0, 0]), "las demás ranuras no cambian")
	assert_eq(d.c.stamina, 1000, "no cuesta resistencia")


func test_cast_zero_commits_on_the_tick_it_starts() -> void:
	_mutate("res://data/combat/shield_bash.tres", &"cast_s", 0.0)
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq(bash.cast_ticks, 0, "lanzamiento 0")
	var d := _sword_driver()
	d.step(ABILITY_1)
	var p: int = d.tick
	assert_eq(d.c.action, Action.ABILITY, "empieza")
	assert_eq(d.c.ability_ready[0], p + bash.cooldown_ticks, "y se compromete en el mismo tick")
	assert_true(ActionMachine.is_commit_tick(d.c, p), "su primer tick es el compromiso")
	assert_eq(ActionMachine.phase(d.c, p), ActionMachine.PHASE_ACTIVE, "sin lanzamiento")


func test_the_ability_is_ready_again_exactly_at_ability_ready_and_not_before() -> void:
	var d := _sword_driver()
	d.step(ABILITY_1)
	d.hold(0, 60)
	var ready: int = d.c.ability_ready[0]
	assert_true(ready > d.tick, "en reutilización")
	assert_eq(ActionMachine.ability_status(d.c, 0, d.tick), ActionMachine.AbilityStatus.COOLDOWN,
			"la barra la ve en reutilización")
	# Pulsada un tick antes: va al búfer y sale justo en ready.
	var early := MachineDriver.new(d.c.weapon_id)
	early.c.copy_from(d.c)
	early.tick = d.tick
	early.idle_until_before(ready - 1)
	early.step(ABILITY_1)
	assert_eq(early.c.action, Action.NONE, "en ready - 1 no empieza")
	assert_eq(early.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "va al búfer")
	early.step()
	assert_eq(early.c.action, Action.ABILITY, "sale del búfer en ready")
	assert_eq(early.c.action_tick, ready, "exactamente en ready")
	# Pulsada 9 ticks antes: el búfer caduca en ready - 1 y no empieza nada.
	var late := MachineDriver.new(d.c.weapon_id)
	late.c.copy_from(d.c)
	late.tick = d.tick
	late.idle_until_before(ready - 9)
	late.step(ABILITY_1)
	late.idle_until_before(ready + 1)
	assert_eq(late.c.buffered, 0, "el búfer caducó")
	assert_eq(late.c.action, Action.NONE, "sin empezar en ready")
	# Y una pulsación en ready empieza al momento.
	var exact := MachineDriver.new(d.c.weapon_id)
	exact.c.copy_from(d.c)
	exact.tick = d.tick
	exact.idle_until_before(ready)
	assert_eq(ActionMachine.ability_status(exact.c, 0, ready), ActionMachine.AbilityStatus.READY,
			"lista en ready")
	exact.step(ABILITY_1)
	assert_eq(exact.c.action, Action.ABILITY, "pulsada en ready empieza")


func test_a_stagger_in_the_cast_leaves_no_cooldown() -> void:
	var d := _sword_driver()
	d.step(ABILITY_1)
	d.hold(0, 10)
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2.ZERO)
	assert_eq(d.c.action, Action.STAGGER, "tambaleado en el lanzamiento")
	d.hold(0, 25)
	assert_eq(d.c.action, Action.NONE, "el tambaleo acaba")
	assert_eq(d.c.ability_ready[0], 0, "un control antes del compromiso no gasta la reutilización")
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "y se puede volver a usar")


# --- Canalización ------------------------------------------------------------------------------

func test_a_stagger_cuts_a_channel_and_sets_its_cooldown_on_that_tick() -> void:
	var wall: AbilityTicks = _ability(&"shield_wall")
	assert_eq([wall.cast_ticks, wall.active_ticks, wall.recovery_ticks, wall.cooldown_ticks],
			[12, 360, 0, 1080], "muro: 12 + hasta 360, 18 s")
	assert_true(wall.channel and wall.channel_hold and wall.blocks, "canalizado, se mantiene, bloquea")
	var d := _sword_driver()
	d.step(ABILITY_3)
	var p: int = d.tick
	d.hold(ABILITY_3, 39)
	assert_eq(d.c.ability_ready[2], 0, "una canalización no fija nada en el compromiso")
	var s: int = d.tick
	ActionMachine.impose_stagger(d.c, s, s + 30, Vector2(1.0, 0.0))
	assert_eq(d.c.action, Action.STAGGER, "el tambaleo corta el muro")
	assert_eq(d.c.ability_ready[2], s + 1080, "y fija su reutilización en ese tick")
	assert_eq(p + 39, s, "a mitad de la canalización")
	# En el mismo tick del compromiso (ya simulado) también cuenta; uno antes, no.
	var at_commit := _sword_driver()
	at_commit.step(ABILITY_3)
	at_commit.hold(ABILITY_3, 12)
	ActionMachine.impose_stun(at_commit.c, at_commit.tick, at_commit.tick + 30)
	assert_eq(at_commit.c.ability_ready[2], at_commit.tick + 1080,
			"aturdido en el tick del compromiso: ya está comprometida")
	var before := _sword_driver()
	before.step(ABILITY_3)
	before.hold(ABILITY_3, 11)
	ActionMachine.impose_stun(before.c, before.tick, before.tick + 30)
	assert_eq(before.c.ability_ready[2], 0, "en el lanzamiento: sin reutilización")
	var killed := _sword_driver()
	killed.step(ABILITY_3)
	killed.hold(ABILITY_3, 30)
	ActionMachine.impose_death(killed.c, killed.tick)
	assert_eq(killed.c.ability_ready[2], killed.tick + 1080, "la muerte también la fija")


func test_releasing_moving_and_the_cap_end_the_channel() -> void:
	# Soltar.
	var d := _sword_driver()
	d.step(ABILITY_3)
	var p: int = d.tick
	d.hold(ABILITY_3, 99)
	assert_eq(d.c.action, Action.ABILITY, "mantenido, sigue")
	d.step()
	assert_eq(d.c.action, Action.NONE, "soltar el 3 lo acaba")
	assert_eq(d.c.action_tick, p, "conservando el action_tick de lo que acaba")
	assert_eq(d.c.ability_ready[2], p + 100 + 1080, "con la reutilización desde ese tick")
	# Las entradas sustituidas no lo sueltan.
	var held := _sword_driver()
	held.step(ABILITY_3)
	held.hold(ABILITY_3, 40)
	held.hold(0, 5, true)
	assert_eq(held.c.action, Action.ABILITY, "una sustituida sin el botón no lo suelta")
	held.step()
	assert_eq(held.c.action, Action.NONE, "la primera real sin el botón, sí")
	# El tope: 12 + 360.
	var capped := _sword_driver()
	capped.step(ABILITY_3)
	var q: int = capped.tick
	capped.idle_until_before(q + 372, ABILITY_3)
	assert_eq(capped.c.action, Action.ABILITY, "sigue hasta el tope")
	assert_true(ActionMachine.defense_flags(capped.c, capped.tick) & ActionMachine.DEFENSE_WIDE_BLOCK != 0,
			"bloqueando hasta el último tick")
	capped.step(ABILITY_3)
	assert_eq(capped.c.action, Action.NONE, "a los 372 ticks acaba solo")
	assert_eq(capped.c.ability_ready[2], q + 372 + 1080, "con su reutilización")
	# Moverse, si lo dice el dato.
	_mutate("res://data/combat/shield_wall.tres", &"channel_breaks_on_move", true)
	var mover := _sword_driver()
	mover.step(ABILITY_3)
	var m: int = mover.tick
	mover.move = Vector2(0.0, 1.0)
	mover.hold(ABILITY_3, 5)
	assert_eq(mover.c.action, Action.ABILITY, "moverse en el lanzamiento no la rompe")
	mover.move = Vector2.ZERO
	mover.idle_until_before(m + 30, ABILITY_3)
	mover.move = Vector2(0.0, 1.0)
	mover.step(ABILITY_3, true)
	assert_eq(mover.c.action, Action.ABILITY, "una sustituida con movimiento tampoco")
	mover.step(ABILITY_3)
	assert_eq(mover.c.action, Action.NONE, "una real con |move| >= 0,1 la acaba")
	assert_eq(mover.c.ability_ready[2], m + 31 + 1080, "con su reutilización")


func test_release_and_press_primary_in_the_same_tick() -> void:
	# docs/habilidades.md, sección 3.3: soltar 3 y pulsar PRIMARY en el mismo tick acaba el muro en 4a
	# y el ligero sale en 4c, en ese tick.
	var d := _sword_driver()
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 50)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "el ligero sale en el mismo tick")
	assert_eq(d.c.action_tick, d.tick, "en ese tick")
	assert_eq(d.c.ability_ready[2], d.tick + 1080, "y el muro fijó su reutilización")


func test_a_tap_shorter_than_the_cast_gives_twelve_ticks_and_no_cooldown() -> void:
	var d := _sword_driver()
	d.step(ABILITY_3)
	var p: int = d.tick
	d.step(ABILITY_3)
	for rel: int in range(2, 12):
		d.step()
		assert_eq(d.c.action, Action.ABILITY, "rel %d: el lanzamiento sigue aunque se suelte" % rel)
		assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "rel %d: sin bloquear aún" % rel)
	d.step()
	assert_eq(d.tick, p + 12, "en el fin del lanzamiento")
	assert_eq(d.c.action, Action.NONE, "acaba sin muro")
	assert_eq(d.c.ability_ready[2], 0, "y sin reutilización")


func test_release_on_the_commit_tick_and_one_tick_after() -> void:
	var on_commit := _sword_driver()
	on_commit.step(ABILITY_3)
	var p: int = on_commit.tick
	on_commit.hold(ABILITY_3, 11)
	on_commit.step()
	assert_eq(on_commit.tick, p + 12, "suelta en el compromiso")
	assert_eq(on_commit.c.action, Action.NONE, "se cancela")
	assert_eq(on_commit.c.ability_ready[2], 0, "sin reutilización")
	var after := _sword_driver()
	after.step(ABILITY_3)
	var q: int = after.tick
	after.hold(ABILITY_3, 12)
	assert_eq(ActionMachine.defense_flags(after.c, q + 12),
			ActionMachine.DEFENSE_BLOCKING | ActionMachine.DEFENSE_WIDE_BLOCK, "un tick de muro")
	after.step()
	assert_eq(after.c.action, Action.NONE, "suelta uno después")
	assert_eq(after.c.ability_ready[2], q + 13 + 1080, "y son 18 s")
	# Esquivar en el tick del compromiso tampoco la gasta.
	var dodged := _sword_driver()
	dodged.step(ABILITY_3)
	var r: int = dodged.tick
	dodged.hold(ABILITY_3, 11)
	dodged.step(ABILITY_3 | DODGE)
	assert_eq(dodged.c.action, Action.DODGE, "la esquiva corta el muro desde el fin del lanzamiento")
	assert_eq(dodged.c.action_tick, r + 12, "en el compromiso")
	assert_eq(dodged.c.ability_ready[2], 0, "sin reutilización")
	var dodged_later := _sword_driver()
	dodged_later.step(ABILITY_3)
	var u: int = dodged_later.tick
	dodged_later.hold(ABILITY_3, 19)
	dodged_later.step(ABILITY_3 | DODGE)
	assert_eq(dodged_later.c.action, Action.DODGE, "esquiva en plena canalización")
	assert_eq(dodged_later.c.ability_ready[2], u + 20 + 1080, "con la reutilización de ese tick")


func test_a_buffered_wall_needs_its_button_down() -> void:
	# Pulsado en el golpe activo de un ligero (sale del búfer en la recuperación, rel 18).
	var up := _sword_driver()
	up.step(PRIMARY)
	var p: int = up.tick
	up.idle_until_before(p + 12)
	up.step(ABILITY_3)
	assert_eq(up.c.buffered_type(), CombatState.BUFFER_ABILITY_3, "al búfer")
	up.step()
	assert_eq(up.c.buffered, 0, "con el botón suelto se descarta")
	up.idle_until_before(p + 20)
	assert_eq(up.c.action, Action.LIGHT, "y no hay muro")
	var down := _sword_driver()
	down.step(PRIMARY)
	var q: int = down.tick
	down.idle_until_before(q + 12)
	down.idle_until_before(q + 19, ABILITY_3)
	assert_eq(down.c.action, Action.ABILITY, "mantenido, sale en la recuperación del ligero")
	assert_eq(down.c.action_tick, q + 18, "en el primer tick de la recuperación")


# --- Prioridades, búfer y entradas sustituidas ---------------------------------------------------

func test_simultaneous_edges_follow_the_priority() -> void:
	var bash: int = _ability(&"shield_bash").id
	var rush: int = _ability(&"shield_rush").id
	var health: int = CombatCatalog.consumable_ids()[0]
	# [botones, acción, action_id (-1 = no importa), qué queda en el búfer, mensaje]
	var cases: Array = [
		[DODGE | ABILITY_1, Action.DODGE, -1, CombatState.BUFFER_ABILITY_1, "DODGE > ABILITY_1"],
		[ABILITY_1 | ABILITY_2, Action.ABILITY, bash, CombatState.BUFFER_ABILITY_2,
				"ABILITY_1 > ABILITY_2"],
		[ABILITY_2 | ABILITY_3, Action.ABILITY, rush, CombatState.BUFFER_ABILITY_3,
				"ABILITY_2 > ABILITY_3"],
		[ABILITY_3 | CONSUMABLE_1, Action.ABILITY, _ability(&"shield_wall").id,
				CombatState.BUFFER_CONSUMABLE_1, "ABILITY_3 > CONSUMABLE_1"],
		[CONSUMABLE_1 | PlayerInput.CONSUMABLE_2, Action.ABILITY, health,
				CombatState.BUFFER_CONSUMABLE_2, "CONSUMABLE_1 > CONSUMABLE_2"],
		[PlayerInput.CONSUMABLE_2 | PRIMARY, Action.ABILITY, CombatCatalog.consumable_ids()[1],
				CombatState.BUFFER_PRIMARY, "CONSUMABLE_2 > PRIMARY"],
		[PRIMARY | SWAP, Action.LIGHT, -1, CombatState.BUFFER_SWAP, "PRIMARY > SWAP"],
		[SWAP | BLOCK, Action.SWAP, -1, CombatState.BUFFER_NONE, "SWAP > BLOCK"],
	]
	for case: Array in cases:
		var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 2))
		d.step(case[0])
		assert_eq(d.c.action, case[1], case[4])
		if case[2] >= 0:
			assert_eq(d.c.action_id, case[2], "%s: la que gana" % case[4])
		assert_eq(d.c.buffered_type(), case[3], "%s: la otra queda en el búfer" % case[4])


func test_an_ability_pressed_in_a_light_is_buffered_until_its_recovery() -> void:
	var d := _sword_driver()
	d.step(PRIMARY)
	var p: int = d.tick
	d.idle_until_before(p + 13)
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.LIGHT, "en el golpe activo no empieza")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "va al búfer")
	d.idle_until_before(p + 18)
	assert_eq(d.c.action, Action.LIGHT, "espera")
	d.step()
	assert_eq(d.c.action, Action.ABILITY, "sale en la recuperación del ligero")
	assert_eq(d.c.action_tick, p + 18, "en su primer tick")
	assert_eq(d.c.combo_step, 0, "con el combo a 0")
	# Desde la recuperación de una habilidad sale el ligero.
	d.idle_until_before(p + 18 + 23)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.ABILITY, "en el activo de la habilidad no")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "al búfer")
	d.idle_until_before(p + 18 + 24 + 1)
	assert_eq(d.c.action, Action.LIGHT, "en su recuperación, sí")


func test_an_ability_press_that_expires_after_the_light_restarts_the_combo() -> void:
	var d := _sword_driver()
	d.step(PRIMARY)
	var p: int = d.tick
	d.idle_until_before(p + 30)
	d.step(PRIMARY)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "enlace del segundo ligero")
	# El ligero acaba en el aire: el enlace no sale y pasa a pulsación guardada.
	d.grounded = false
	d.idle_until_before(p + 37)
	assert_eq(d.c.action, Action.NONE, "el ligero acabó")
	assert_eq(d.c.combo_step, 1, "el combo sigue a medias")
	# Una habilidad (sin poder salir en el aire) sustituye a la pulsación y caduca.
	d.step(ABILITY_1)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "la habilidad ocupa el búfer")
	d.hold(0, 8)
	assert_eq(d.c.buffered, 0, "y caduca")
	assert_eq(d.c.combo_step, 0, "dejando el combo a 0")
	assert_eq(d.c.action, Action.NONE, "sin empezar nada")


func test_substituted_inputs_start_nothing() -> void:
	# La sustituta repite los botones de la última entrada aplicada (docs/combate.md, sección 3.2): un
	# toque perdido de un solo tick no inventa nada.
	var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 2))
	d.hold(0, 3)
	d.step(0, true)
	d.step(0)
	assert_eq(d.c.action, Action.NONE, "el toque perdido no empieza nada")
	assert_eq(d.c.buffered, 0, "ni deja nada guardado")
	# Mantener el botón con sustitutas no crea flancos nuevos: un solo cambio de arma.
	d.step(SWAP)
	assert_eq(d.c.action, Action.SWAP, "el flanco real cambia de arma")
	d.hold(SWAP, 40, true)
	assert_eq(d.c.action, Action.NONE, "el cambio acabó")
	assert_eq(d.c.weapon_id, _bow(), "y no se repitió con las sustitutas")
	d.step(SWAP)
	assert_eq(d.c.weapon_id, _bow(), "ni con la real que sigue mantenida")
	# Igual con una poción: una sola carga.
	d.hold(0, 2)
	d.step(CONSUMABLE_1)
	d.hold(CONSUMABLE_1, 60, true)
	assert_eq(d.c.charges_of(0), 2, "una sola carga gastada")
	assert_eq(d.c.action, Action.NONE, "y sin volver a beber")


# --- Cancelaciones, suelo y acciones que lo permiten -------------------------------------------

func test_dodge_cancels_an_ability_only_from_its_cancel_point() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq(bash.cancel_to_dodge_from_ticks, 24, "a esquiva desde la recuperación")
	var d := _sword_driver()
	d.step(ABILITY_1)
	var p: int = d.tick
	d.idle_until_before(p + 20)
	d.step(DODGE)
	assert_eq(d.c.action, Action.ABILITY, "en el activo no se esquiva")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "va al búfer")
	d.idle_until_before(p + 25)
	assert_eq(d.c.action, Action.DODGE, "sale en la recuperación")
	assert_eq(d.c.action_tick, p + 24, "en su primer tick")
	assert_eq(d.c.ability_ready[0], p + 18 + 720, "la reutilización ya estaba fijada")


func test_abilities_need_the_ground_and_an_action_that_allows_them() -> void:
	# En el aire, al búfer; al tocar el suelo, sale.
	var air := _sword_driver()
	air.grounded = false
	air.step(ABILITY_1)
	assert_eq(air.c.action, Action.NONE, "en el aire no empieza")
	assert_eq(air.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "va al búfer")
	air.grounded = true
	air.step()
	assert_eq(air.c.action, Action.ABILITY, "al aterrizar sale")
	# Desde la carga: la cancela sin gastar.
	var charge := _sword_driver()
	charge.hold(PRIMARY, 8)
	assert_eq(charge.c.action, Action.CHARGE, "cargando")
	charge.step(PRIMARY | ABILITY_2)
	assert_eq(charge.c.action, Action.ABILITY, "la habilidad cancela la carga")
	assert_eq(charge.c.stamina, 1000, "sin gastar el fuerte")
	# Desde el bloqueo, y al acabar vuelve a bloquear si se mantiene.
	var block := _sword_driver()
	block.hold(BLOCK, 3)
	block.step(BLOCK | ABILITY_1)
	assert_eq(block.c.action, Action.ABILITY, "desde el bloqueo")
	block.hold(BLOCK, 48)
	assert_eq(block.c.action, Action.BLOCK, "al acabar, el bloqueo a nivel")
	# En la anticipación de un ligero, al búfer.
	var light := _sword_driver()
	light.step(PRIMARY)
	light.step(ABILITY_1)
	assert_eq(light.c.action, Action.LIGHT, "no corta la anticipación")
	# Desde un aturdimiento, nada (y el búfer caduca).
	var stunned := _sword_driver()
	stunned.step()
	ActionMachine.impose_stun(stunned.c, stunned.tick, stunned.tick + 30)
	stunned.step(ABILITY_1)
	stunned.hold(0, 9)
	assert_eq(stunned.c.action, Action.STUN, "aturdido")
	assert_eq(stunned.c.buffered, 0, "la pulsación caducó")


func test_an_empty_slot_drops_the_press() -> void:
	var npc_weapon: int = CombatCatalog.weapon_id(&"npc_guard")
	assert_true(npc_weapon != 0, "arma de PNJ sin habilidades")
	var d := MachineDriver.new(npc_weapon)
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.NONE, "sin habilidad en la ranura no pasa nada")
	assert_eq(d.c.buffered, 0, "y no se guarda")
	assert_eq(ActionMachine.ability_status(d.c, 0, d.tick), ActionMachine.AbilityStatus.EMPTY,
			"la casilla está vacía")


func test_exhaustion_blocks_the_wall_but_not_the_other_abilities() -> void:
	var d := _sword_driver()
	ActionMachine.drain_stamina(d.c, 5000, d.tick)
	assert_true(d.c.is_exhausted(), "agotado")
	assert_eq(ActionMachine.ability_status(d.c, 2, d.tick), ActionMachine.AbilityStatus.BLOCKED,
			"la casilla del muro se apaga")
	d.step(ABILITY_3)
	assert_eq(d.c.action, Action.NONE, "agotado no se levanta el muro")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "y avisa a la interfaz")
	assert_eq(d.c.buffered, 0, "sin guardar la pulsación")
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "el golpe de escudo sí sale")


func test_no_cooldowns_flag_spends_nothing() -> void:
	var d := _sword_driver()
	d.c.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	d.step(ABILITY_1)
	d.hold(0, 48)
	assert_eq(d.c.ability_ready[0], 0, "con el bit 7 no se fija la reutilización")
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "y se puede repetir al acabar")
	d.hold(0, 60)
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 30)
	d.step()
	assert_eq(d.c.ability_ready[2], 0, "tampoco al acabar una canalización")


# --- Consultas ----------------------------------------------------------------------------------

func test_queries_active_hit_status_and_defense() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 0))
	for slot: int in 3:
		assert_eq(ActionMachine.ability_status(d.c, slot, d.tick), ActionMachine.AbilityStatus.READY,
				"ranura %d lista" % slot)
	assert_eq(ActionMachine.ability_status(d.c, ActionMachine.STATUS_SLOT_CONSUMABLE_1, d.tick),
			ActionMachine.AbilityStatus.READY, "la poción 1 tiene cargas")
	assert_eq(ActionMachine.ability_status(d.c, ActionMachine.STATUS_SLOT_CONSUMABLE_2, d.tick),
			ActionMachine.AbilityStatus.NO_CHARGES, "la 2, no")
	d.step(ABILITY_1)
	var p: int = d.tick
	assert_eq(ActionMachine.ability_status(d.c, 1, p), ActionMachine.AbilityStatus.BLOCKED,
			"en el lanzamiento las demás se apagan")
	for rel: int in range(0, 48):
		var hit: AttackTicks = ActionMachine.active_hit(d.c, p + rel)
		if rel >= 18 and rel < 24:
			assert_true(hit == bash.hit, "rel %d: el golpe sintetizado en el activo" % rel)
		else:
			assert_null(hit, "rel %d: sin golpe" % rel)
	assert_eq(bash.hit.id, CombatSource.make(CombatSource.Kind.ABILITY, bash.id),
			"su id es la fuente de la habilidad")
	assert_eq(ActionMachine.defense_flags(d.c, p + 20), 0, "el golpe de escudo no defiende")
	assert_false(ActionMachine.is_attack_active(d.c, p + 20), "is_attack_active sigue siendo de ataques")
	# Un ligero también tiene su golpe activo.
	var light := _sword_driver()
	light.step(PRIMARY)
	var attack: AttackTicks = CombatCatalog.attack(light.c.action_id)
	assert_true(ActionMachine.active_hit(light.c, light.tick + 12) == attack, "el ataque en su activo")
	assert_null(ActionMachine.active_hit(light.c, light.tick + 11), "no en la anticipación")
	assert_true(ActionMachine.is_commit_tick(light.c, light.tick + 12), "su compromiso")
	# El muro bloquea ancho en la canalización.
	var wall := _sword_driver()
	wall.step(ABILITY_3)
	var w: int = wall.tick
	wall.hold(ABILITY_3, 20)
	assert_eq(ActionMachine.defense_flags(wall.c, wall.tick),
			ActionMachine.DEFENSE_BLOCKING | ActionMachine.DEFENSE_WIDE_BLOCK, "bloqueo ancho")
	assert_true(ActionMachine.is_blocking(wall.c, wall.tick), "is_blocking lo cuenta")
	assert_false(ActionMachine.is_blocking(wall.c, w + 5), "no en el lanzamiento")
	assert_null(ActionMachine.active_hit(wall.c, wall.tick).shape, "el muro no golpea (sin forma)")


func test_stamina_does_not_regenerate_in_a_blocking_channel() -> void:
	var d := _sword_driver()
	ActionMachine.drain_stamina(d.c, 500, d.tick)
	d.hold(0, 40)
	var regenerating: int = d.c.stamina
	assert_true(regenerating > 500, "regenera tras el retardo (%d)" % regenerating)
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 11)
	assert_eq(d.c.stamina, regenerating + 12 * 3, "en el lanzamiento sigue regenerando")
	var channel_start: int = d.c.stamina
	d.hold(ABILITY_3, 60)
	assert_eq(d.c.stamina, channel_start, "en la canalización que bloquea, no")
	d.step()
	assert_eq(d.c.action, Action.NONE, "soltado")
	assert_eq(d.c.stamina, channel_start, "la regeneración va antes de las entradas: aún no")
	d.step()
	assert_eq(d.c.stamina, channel_start + 3, "en el tick siguiente vuelve a regenerar")


func test_the_rush_dash_follows_its_baked_window_and_direction() -> void:
	var rush: AbilityTicks = _ability(&"shield_rush")
	assert_eq([rush.cast_ticks, rush.active_ticks, rush.recovery_ticks], [9, 24, 21], "embestida")
	assert_eq([rush.dash_from_ticks, rush.dash_to_ticks], [9, 33], "avance en el activo")
	var total: float = 0.0
	for speed: float in rush.dash_speeds:
		total += speed / 60.0
	assert_near(total, 6.0, 1e-4, "6 m horneados")
	var d := _sword_driver()
	d.look_yaw = 0.7
	d.step(ABILITY_2)
	var p: int = d.tick
	assert_eq(d.c.action_dir, CombatState.quantize_yaw(0.7), "dirección hacia la cámara al empezar")
	d.look_yaw = -1.0
	for rel: int in range(1, 54):
		var out: ActionMachine.Output = d.step()
		if rel < 9:
			assert_false(out.forced_velocity, "rel %d: lanzamiento libre" % rel)
			assert_near(out.turn_rate, 6.0, 1e-6, "rel %d: gira hacia la cámara" % rel)
		elif rel < 33:
			assert_true(out.forced_velocity, "rel %d: avance impuesto" % rel)
			assert_eq(out.turn_rate, 0.0, "rel %d: sin giro" % rel)
			var expected := Vector3(-sin(CombatState.dequantize_yaw(d.c.action_dir)), 0.0,
					-cos(CombatState.dequantize_yaw(d.c.action_dir))) * rush.dash_speed_at(rel)
			assert_vec_near(out.velocity, expected, 1e-5, "rel %d: hacia el yaw del inicio" % rel)
		else:
			assert_false(out.forced_velocity, "rel %d: recuperación sin avance" % rel)
	assert_eq(d.tick, p + 53, "recorrida entera")
	# El salto atrás del arco va hacia atrás desde el primer tick.
	var bow := MachineDriver.new(_bow())
	bow.look_yaw = 0.25
	var first: ActionMachine.Output = bow.step(ABILITY_3)
	var leap: AbilityTicks = _ability(&"bow_evasive_shot")
	assert_eq(bow.c.action_id, leap.id, "salto atrás con disparo")
	assert_eq(bow.c.action_dir, CombatState.quantize_yaw(0.25 + PI), "hacia atrás")
	assert_true(first.forced_velocity and first.snap_yaw, "avanza ya en el primer tick, mirando a la cámara")
	assert_true(first.velocity.dot(Vector3(-sin(0.25), 0.0, -cos(0.25))) < 0.0, "alejándose")


# --- Lo que impone el servidor ------------------------------------------------------------------

func test_downed_only_crawls_and_does_not_end_alone() -> void:
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var d := _sword_driver()
	d.step(PRIMARY)
	ActionMachine.impose_move_effect(d.c, slowed, d.tick + 500)
	d.c.buffered = CombatState.pack_buffer(CombatState.BUFFER_DODGE, 5)
	ActionMachine.impose_downed(d.c, d.tick)
	var s: int = d.tick
	assert_eq(d.c.action, Action.DOWNED, "derribado")
	assert_eq(d.c.action_tick, s, "desde ese tick")
	assert_eq([d.c.buffered, d.c.primary_held, d.c.combo_step], [0, 0, 0], "sin búfer, pulsación ni combo")
	assert_eq(d.c.move_effect_ids, PackedInt32Array([0, 0]), "sin efectos de movimiento")
	assert_eq(ActionMachine.defense_flags(d.c, s), 0, "un derribado no defiende")
	ActionMachine.impose_stagger(d.c, s, s + 30, Vector2(2.0, 0.0))
	ActionMachine.impose_stun(d.c, s, s + 30)
	assert_eq(d.c.action, Action.DOWNED, "ni tambaleo ni aturdimiento sobre un derribado")
	var out: ActionMachine.Output = d.step(PRIMARY | DODGE | ABILITY_1 | SWAP)
	assert_eq(d.c.action, Action.DOWNED, "no actúa")
	assert_eq(d.c.buffered, 0, "ni guarda")
	assert_true(out.scaled_movement, "se arrastra")
	assert_near(out.move_scale, 0.15, 1e-6, "×0,15")
	assert_near(out.turn_rate, 3.0, 1e-6, "gira a 3")
	assert_false(out.allow_jump or out.allow_sprint, "sin salto ni esprint")
	d.hold(0, 1500)
	assert_eq(d.c.action, Action.DOWNED, "no termina solo")
	ActionMachine.impose_revived(d.c, d.tick)
	assert_eq(d.c.action, Action.NONE, "levantado")
	assert_eq(d.c.action_tick, d.tick, "desde ese tick")
	var dead := _sword_driver()
	dead.step()
	ActionMachine.impose_death(dead.c, dead.tick)
	ActionMachine.impose_stun(dead.c, dead.tick, dead.tick + 30)
	assert_eq(dead.c.action, Action.DEAD, "tampoco sobre un muerto")


func test_revive_and_execute_end_by_time_by_release_or_by_dodge() -> void:
	var data: CombatTables = CombatCatalog.tables()
	assert_eq([data.revive_ticks, data.execute_ticks], [180, 60], "3 s y 1 s")
	var d := _sword_driver()
	d.step(INTERACT)
	ActionMachine.impose_interact(d.c, d.tick, Action.REVIVE)
	var s: int = d.tick
	assert_eq(d.c.action, Action.REVIVE, "levantando")
	var out: ActionMachine.Output = d.step(INTERACT)
	assert_eq(out.move_scale, 0.0, "frena")
	assert_eq(out.turn_rate, 0.0, "sin giro")
	assert_false(out.allow_jump, "ni salto")
	d.idle_until_before(s + 180, INTERACT)
	assert_eq(d.c.action, Action.REVIVE, "sigue hasta el final")
	d.step(INTERACT)
	assert_eq(d.c.action, Action.NONE, "acaba a los 180 ticks")
	# Soltar INTERACT con una entrada real lo acaba; una sustituida, no.
	var released := _sword_driver()
	released.step(INTERACT)
	ActionMachine.impose_interact(released.c, released.tick, Action.EXECUTE)
	var e: int = released.tick
	released.hold(0, 3, true)
	assert_eq(released.c.action, Action.EXECUTE, "rematando aunque la sustituta no traiga INTERACT")
	released.step()
	assert_eq(released.c.action, Action.NONE, "la primera real sin INTERACT lo corta")
	assert_eq(released.c.action_tick, e, "conservando el action_tick")
	# Rematar dura 60.
	var execute := _sword_driver()
	execute.step(INTERACT)
	ActionMachine.impose_interact(execute.c, execute.tick, Action.EXECUTE)
	var x: int = execute.tick
	execute.idle_until_before(x + 60, INTERACT)
	assert_eq(execute.c.action, Action.EXECUTE, "rematando")
	execute.step(INTERACT)
	assert_eq(execute.c.action, Action.NONE, "a los 60 ticks")
	# La esquiva lo corta.
	var dodge := _sword_driver()
	dodge.step(INTERACT)
	ActionMachine.impose_interact(dodge.c, dodge.tick, Action.REVIVE)
	dodge.step(INTERACT | DODGE)
	assert_eq(dodge.c.action, Action.DODGE, "esquivar corta levantar")
	# Otra acción no se impone así; la interrupción corta conservando el action_tick.
	var other := _sword_driver()
	ActionMachine.impose_interact(other.c, other.tick, Action.STUN)
	assert_eq(other.c.action, Action.NONE, "solo REVIVE o EXECUTE")
	other.step(INTERACT)
	ActionMachine.impose_interact(other.c, other.tick, Action.REVIVE)
	var r: int = other.tick
	other.hold(INTERACT, 30)
	ActionMachine.impose_interrupt(other.c, other.tick)
	assert_eq(other.c.action, Action.NONE, "interrumpido")
	assert_eq(other.c.action_tick, r, "conserva el action_tick de lo que corta")


# --- Utilidades ---------------------------------------------------------------------------------

func _sword() -> int:
	return CombatCatalog.weapon_id(&"sword_shield")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")


func _ability(ability_name: StringName) -> AbilityTicks:
	return CombatCatalog.ability(CombatCatalog.ability_id(ability_name))


func _sword_driver() -> MachineDriver:
	return MachineDriver.new(_sword(), 0, CombatState.pack_charges(3, 2))


## Cambia [param property] de un recurso de datos y recarga el catálogo (se deshace en after_each).
func _mutate(path: String, property: StringName, value: Variant) -> void:
	var resource: Resource = load(path)
	_mutations.append([resource, property, resource.get(property)])
	resource.set(property, value)
	CombatCatalog.reload()
	assert_true(CombatCatalog.tables().is_valid(), "el catálogo cambiado sigue siendo válido: %s"
			% ", ".join(CombatCatalog.tables().errors))
