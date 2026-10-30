extends TestCase
## Las habilidades en el servidor (docs/habilidades.md, secciones 3.6, 4.1 y 4.2; paquete H3a): el golpe de
## escudo aturde de frente, atraviesa un escudo en alto y no da por detrás; la embestida recorre 6 m en su
## activo y empuja; el muro de escudos bloquea a 85° del frente y no a 95°; el servidor rechaza una
## habilidad en reutilización (un bot que la pulsa un tick de cada dos compromete exactamente cada
## [code]cooldown + cast[/code] ticks); una habilidad quita la protección de reaparición y beber no; un golpe
## interrumpe beber antes del compromiso y no después; la muestra antigua del bloqueo no cuenta tras un
## REVIVE soltado ni tras una poción interrumpida dentro del rebobinado; la ranura 2 activa nunca llega al
## historial como bloqueo; y desde dentro del vano de una puerta cerrada ni se golpea hacia fuera ni se
## recibe.
## [br][br]
## Las cortas montan los luchadores a mano y avanzan el [CombatDirector] tick a tick (como
## test_combat_director); las largas usan un [ZoneServer] sin red con jugadores falsos que se avanza a mano
## con [code]_physics_process[/code] (como tools/combat_balance.gd), sin esperar fotogramas.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const TICK_DELTA: float = 1.0 / 60.0

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
# Servidor de las pruebas largas (null en las demás).
var _server: ZoneServer = null
var _server_viewport: SubViewport = null
var _server_events: Array[NetMessages.EntityEvent] = []


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, SafeAreas.new(),
			CombatFixture.place, _pick_spawn)
	_events.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _events.append(event))
	await wait_physics_frames(3)


func after_each() -> void:
	_director = null
	if is_instance_valid(_server):
		_server.stop()
		_server.free()
	_server = null
	for viewport: SubViewport in [_viewport, _server_viewport]:
		if is_instance_valid(viewport):
			viewport.get_parent().remove_child(viewport)
			viewport.free()
	_viewport = null
	_server_viewport = null
	_world = null
	_server_events.clear()
	await wait_process_frames()


# --- Ayudantes del director -------------------------------------------------------------------

func _pick_spawn(realm: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(100.0 + float(realm), 0.0, 100.0))


func _body(net_id: int, realm: int, position: Vector3, yaw: float, peer: ServerPeer = null) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), peer)


func _ability(ability_name: StringName) -> AbilityTicks:
	var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(ability_name))
	assert_not_null(ability, "la habilidad %s existe" % ability_name)
	return ability


## Pone a [param fighter] en la habilidad [param ability] empezada en [param action_tick].
func _start_ability(fighter: Combatant, ability: AbilityTicks, action_tick: int) -> void:
	var combat: CombatState = fighter.get_character().combat
	combat.action = CombatState.Action.ABILITY
	combat.action_id = ability.id
	combat.action_tick = action_tick


func _tick(s: int = S) -> void:
	_director.process_tick(s, _world.get_world_3d().direct_space_state)


func _hits_on(net_id: int, events: Array[NetMessages.EntityEvent] = _events) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in events:
		if event.event == HIT and event.net_id == net_id:
			found.append(event)
	return found


func _combat_of(combatant: Combatant) -> CombatState:
	return combatant.get_character().combat


## Un peer con RTT de 4 ticks y 6 de interpolación (tope de rebobinado 12) y la entrada real del tick
## [param s] del atacante con [param view_offset] ticks de vista atrás, consumida.
func _rewinding_attacker(net_id: int, position: Vector3, yaw: float, view_offset: int) -> Combatant:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	var attacker: Combatant = _body(net_id, VARDHEIM, position, yaw, peer)
	attacker.queue.reset(S - 1, NetProtocol.neutral_input(S - 1, yaw))
	attacker.queue.push(NetProtocol.neutral_input(S, yaw), view_offset * CombatResolver.VIEW_OFFSET_Q_SCALE, S)
	attacker.queue.take(S)
	return attacker


## Resuelve el tick [param s] con el resolutor del director (sin aplicar nada): congela a todos, olvidando
## antes a quién había golpeado cada uno.
func _resolve(s: int = S) -> Array[CombatResolver.Hit]:
	var list: Array[Combatant] = _director.get_sorted()
	for fighter: Combatant in list:
		fighter.forget_swing()
		fighter.freeze(s)
	return _director.resolver.resolve(s, list, _world.get_world_3d().direct_space_state)


# --- Ayudantes del servidor -------------------------------------------------------------------

## Un [ZoneServer] sin red en una zona plana, que se avanza a mano con [method _step].
func _start_server() -> void:
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_server_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = String(ZONE_ID)
	config.no_dummies = true
	assert_eq(_server.start(config, NetHarness.get_world(_server_viewport), null, DevAuthProvider.new()), OK,
			"el servidor arranca")
	_server.set_physics_process(false)
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _server_events.append(event))


## Un jugador falso de [param realm] en [param position] mirando a [param yaw] cuyas entradas salen de
## [param script] ([code](tick) -> buttons[/code]), con la cámara hacia [param yaw].
func _fake(realm: int, position: Vector3, yaw: float, script: Callable = Callable()) -> int:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		if script.is_valid():
			input.buttons = script.call(tick)
		return input
	var net_id: int = _server.add_fake_player(brain, realm)
	_server.teleport(net_id, position)
	_server.get_registry().get_entity(net_id).get_character().yaw = yaw
	return net_id


## Avanza el servidor [param count] ticks, dentro de un tick de física del motor (move_and_slide usa su
## delta), llamando a [param each] ([code](tick) -> void[/code]) tras cada uno.
func _step(count: int, each: Callable = Callable()) -> void:
	await tree.physics_frame
	for _i: int in count:
		_server._physics_process(TICK_DELTA)
		if each.is_valid():
			each.call(_server.get_tick())


func _server_combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


# --- Golpe de escudo --------------------------------------------------------------------------

func test_the_shield_bash_stuns_in_front_through_a_raised_shield_and_not_behind() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq([bash.cast_ticks, bash.active_ticks, bash.hit.stun_ticks], [18, 6, 48], "0,3 + 0,1 s; aturde 0,8 s")
	assert_true(bash.hit.unblockable, "imbloqueable")
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var front: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var behind: Combatant = _body(3, SOLMARCH, Vector3(0.0, 0.0, 1.5), 0.0)
	CombatFixture.start_block(front, S - 30)
	_start_ability(attacker, bash, S - bash.cast_ticks)
	_tick()
	assert_eq(attacker.frozen.hit, bash.hit, "congela el golpe sintetizado de la habilidad")
	assert_true(attacker.frozen.commit, "el primer tick activo es el del compromiso")
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "da al de delante"):
		assert_eq(hits[0].amount, 60, "60 de daño: el escudo no frena un golpe imbloqueable")
		assert_eq(hits[0].hit_flags, 0, "ni bloqueado ni parado")
		assert_eq(hits[0].damage_type, DamageFormula.DamageType.BLUNT, "contundente")
		assert_eq(hits[0].get_source(), CombatSource.make(CombatSource.Kind.ABILITY, bash.id),
				"con la fuente de la habilidad")
	var state: CombatState = _combat_of(front)
	assert_eq(state.action, CombatState.Action.STUN, "aturdido aunque tenía el escudo en alto")
	assert_eq(state.cc_until_tick, S + 48, "0,8 s")
	assert_eq(front.health, 1000 - 60)
	assert_eq(_hits_on(3).size(), 0, "al de detrás no le da")
	assert_eq(behind.health, 1000)
	assert_eq(_combat_of(behind).action, CombatState.Action.NONE)
	# Los demás ticks activos no vuelven a dar al mismo objetivo.
	for tick: int in range(S + 1, S + bash.active_ticks):
		_tick(tick)
	assert_eq(_hits_on(2).size(), 1, "un golpe por acción y objetivo")


# --- Embestida --------------------------------------------------------------------------------

func test_the_shield_rush_travels_six_meters_in_its_active_window_and_pushes() -> void:
	await _start_server()
	var rush: AbilityTicks = _ability(&"shield_rush")
	assert_eq([rush.dash_from_ticks, rush.dash_to_ticks], [9, 33], "avance en el activo")
	var press: int = _server.get_tick() + 5
	var runner: int = _fake(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, func(tick: int) -> int:
		return PlayerInput.ABILITY_2 if tick >= press and tick < press + 2 else 0)
	var target: int = _fake(SOLMARCH, Vector3(0.3, 0.05, -3.0), PI)
	var positions: Dictionary[int, Vector3] = {}
	var started: Array[int] = []
	var knockbacks: Array[Vector2] = []
	await _step(90, func(tick: int) -> void:
		var character: PlayerCharacter = _server.get_registry().get_entity(runner).get_character()
		positions[tick] = character.global_position
		if started.is_empty() and character.combat.action == CombatState.Action.ABILITY:
			started.append(character.combat.action_tick)
		var victim: CombatState = _server.get_registry().get_entity(target).get_character().combat
		if victim.action == CombatState.Action.STAGGER and knockbacks.is_empty():
			knockbacks.append(victim.knockback))
	if not assert_eq(started.size(), 1, "la embestida empieza"):
		return
	var action_tick: int = started[0]
	assert_eq(action_tick, press, "con el flanco")
	var before_dash: Vector3 = positions[action_tick + rush.dash_from_ticks - 1]
	var after_dash: Vector3 = positions[action_tick + rush.dash_to_ticks - 1]
	var travelled: float = Vector2(after_dash.x - before_dash.x, after_dash.z - before_dash.z).length()
	assert_near(travelled, 6.0, 0.3, "recorre 6 m en su ventana de avance (%.3f m)" % travelled)
	assert_true(after_dash.z < before_dash.z - 5.5, "hacia donde mira la cámara (-Z)")
	var last_tick: int = positions.keys().max()
	var total: float = Vector2(positions[last_tick].x - before_dash.x, positions[last_tick].z - before_dash.z).length()
	print("    [embestida] %.3f m en el activo; %.3f m hasta pararse" % [travelled, total])
	# Empuja: tambaleo de 0,4 s y empuje radial de 6 m/s.
	var hits: Array[NetMessages.EntityEvent] = _hits_on(target, _server_events)
	if assert_eq(hits.size(), 1, "golpea una vez al que está en su camino"):
		assert_eq(hits[0].amount, 50)
		assert_eq(hits[0].get_source(), CombatSource.make(CombatSource.Kind.ABILITY, rush.id))
		assert_true(hits[0].tick >= action_tick + rush.cast_ticks and hits[0].tick < action_tick + rush.hit.active_to(),
				"en un tick activo")
	if assert_eq(knockbacks.size(), 1, "lo deja tambaleándose"):
		assert_near(knockbacks[0].length(), 6.0, 0.05, "con un empuje de 6 m/s")
		assert_true(knockbacks[0].y < -4.0, "hacia fuera del que embiste (-Z)")


# --- Muro de escudos --------------------------------------------------------------------------

func test_the_shield_wall_blocks_a_hit_at_85_degrees_and_not_at_95() -> void:
	var wall: AbilityTicks = _ability(&"shield_wall")
	var rules: CombatRules = CombatCatalog.rules()
	assert_eq(rules.ability_block_angle_deg, 180.0)
	# Tres parejas lejos unas de otras: muro a 85°, muro a 95° y un bloqueo normal (120°) a 85°.
	var defenders: Array[Combatant] = []
	var attackers: Array[Combatant] = []
	var angles: Array[float] = [85.0, 95.0, 85.0]
	for index: int in 3:
		var center := Vector3(30.0 * float(index), 0.0, 0.0)
		var defender: Combatant = _body(10 + index, SOLMARCH, center, 0.0)
		var theta: float = deg_to_rad(angles[index])
		var direction: Vector3 = Basis(Vector3.UP, theta) * Vector3.FORWARD
		var attacker: Combatant = _body(20 + index, VARDHEIM, center + direction * 1.5, theta + PI)
		CombatFixture.start_light_active(attacker, S)
		defenders.append(defender)
		attackers.append(attacker)
	_start_ability(defenders[0], wall, S - wall.cast_ticks - 10)
	_start_ability(defenders[1], wall, S - wall.cast_ticks - 10)
	CombatFixture.start_block(defenders[2], S - 30)
	var stamina: int = _combat_of(defenders[0]).stamina
	_tick()
	assert_true((defenders[0].frozen.defense & ActionMachine.DEFENSE_WIDE_BLOCK) != 0, "el muro da el bloqueo ancho")
	var at_85: Array[NetMessages.EntityEvent] = _hits_on(10)
	if assert_eq(at_85.size(), 1):
		assert_true(at_85[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "a 85° el muro bloquea")
		assert_eq(at_85[0].amount, 0)
	assert_eq(defenders[0].health, 1000)
	assert_eq(_combat_of(defenders[0]).stamina, stamina - roundi(90.0 * rules.ability_block_stamina_per_damage),
			"0,6 de resistencia por punto, no el coste del arma")
	assert_eq(_combat_of(defenders[0]).action, CombatState.Action.ABILITY, "y sigue en el muro")
	var at_95: Array[NetMessages.EntityEvent] = _hits_on(11)
	if assert_eq(at_95.size(), 1):
		assert_false(at_95[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "a 95° no")
	assert_eq(defenders[1].health, 1000 - 90)
	var normal: Array[NetMessages.EntityEvent] = _hits_on(12)
	if assert_eq(normal.size(), 1):
		assert_false(normal[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED),
				"el bloqueo del arma (120°) no para lo que está a 85°")
	# Con el muro roto por falta de resistencia: aturdido y la canalización cortada, con su reutilización.
	var broken: Combatant = defenders[0]
	_combat_of(broken).stamina = 10
	attackers[0].forget_swing()
	CombatFixture.start_light_active(attackers[0], S + 100)
	_tick(S + 100)
	var combat: CombatState = _combat_of(broken)
	assert_eq(combat.action, CombatState.Action.STUN, "rotura de guardia")
	assert_eq(combat.ability_ready[wall.slot], S + 100 + wall.cooldown_ticks,
			"el muro cortado fija su reutilización en ese tick")


# --- Reutilización ----------------------------------------------------------------------------

func test_the_server_refuses_an_ability_in_cooldown() -> void:
	await _start_server()
	var bash: AbilityTicks = _ability(&"shield_bash")
	var spammer: int = _fake(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, func(tick: int) -> int:
		# Pulsa el golpe de escudo un tick de cada dos, sin parar.
		return PlayerInput.ABILITY_1 if tick % 2 == 0 else 0)
	var target: int = _fake(SOLMARCH, Vector3(0.0, 0.05, -1.5), PI)
	var commits: Array[int] = []
	await _step(1520, func(tick: int) -> void:
		var frame: Combatant.Frozen = _server_combatant(spammer).frozen
		if frame.commit and frame.action == CombatState.Action.ABILITY:
			commits.append(tick))
	if not assert_eq(commits.size(), 3, "tres usos en 1520 ticks (%s)" % [commits]):
		return
	var period: int = bash.cooldown_ticks + bash.cast_ticks
	assert_eq(commits[1] - commits[0], period, "compromisos separados exactamente cooldown + cast (%d)" % period)
	assert_eq(commits[2] - commits[1], period)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(target, _server_events)
	assert_eq(hits.size(), 3, "un golpe por compromiso: ninguno de más")
	# Con el comando 13 (sin reutilizaciones) vuelve a salir en cuanto lo deja la acción en curso.
	_server.get_combat().set_cooldowns_off(_server_combatant(spammer), true)
	commits.clear()
	await _step(200, func(tick: int) -> void:
		var frame: Combatant.Frozen = _server_combatant(spammer).frozen
		if frame.commit and frame.action == CombatState.Action.ABILITY:
			commits.append(tick))
	assert_true(commits.size() >= 3, "con cooldowns_off sale varias veces en 200 ticks (%d)" % commits.size())


# --- Protección de reaparición ----------------------------------------------------------------

func test_an_ability_drops_the_spawn_protection_and_drinking_does_not() -> void:
	var caster: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var drinker: Combatant = _body(2, VARDHEIM, Vector3(10.0, 0.0, 0.0), 0.0)
	caster.protected_until = S + 100
	drinker.protected_until = S + 100
	_start_ability(caster, _ability(&"shield_bash"), S)
	_start_ability(drinker, _ability(&"potion_health"), S)
	_tick()
	assert_false(caster.is_protected(S + 1), "lanzar una habilidad quita la protección")
	assert_true(drinker.is_protected(S + 1), "beber no")
	# Cambiar de arma tampoco.
	var swapper: CombatState = _combat_of(drinker)
	swapper.action = CombatState.Action.SWAP
	swapper.action_tick = S + 1
	_tick(S + 1)
	assert_true(drinker.is_protected(S + 2), "ni cambiar de arma")


# --- Interrupciones ---------------------------------------------------------------------------

func test_a_hit_interrupts_drinking_before_the_commit_and_not_after() -> void:
	var potion: AbilityTicks = _ability(&"potion_health")
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var drinker: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var combat: CombatState = _combat_of(drinker)
	combat.consumable_charges = CombatState.pack_charges(3, 2)
	_start_ability(drinker, potion, S - 10)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1):
		assert_true(hits[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "HIT con el bit 5")
	assert_eq(combat.action, CombatState.Action.NONE, "deja de beber")
	assert_eq(combat.action_tick, S - 10, "conservando el action_tick de lo que corta")
	assert_eq(combat.charges_of(0), 3, "sin gastar la carga")
	assert_eq(combat.consumable_ready_tick, S + AbilityTicks.REARM_TICKS,
			"ni la reutilización: solo el margen para que un remoto vea el NONE (revisión de H5)")
	assert_eq(_director.stats[&"interrupts"], 1)
	# Ya comprometida (en la recuperación), un golpe no la corta.
	_start_ability(drinker, potion, S + 100 - potion.cast_ticks - 2)
	attacker.forget_swing()
	CombatFixture.start_light_active(attacker, S + 100)
	_tick(S + 100)
	assert_eq(combat.action, CombatState.Action.ABILITY, "tras el compromiso ya no se interrumpe")
	assert_false(_hits_on(2)[1].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED))
	# Levantar también se interrumpe.
	ActionMachine.impose_interact(combat, S + 190, CombatState.Action.REVIVE)
	attacker.forget_swing()
	CombatFixture.start_light_active(attacker, S + 200)
	_tick(S + 200)
	assert_eq(combat.action, CombatState.Action.NONE, "un impacto corta levantar")
	assert_true(_hits_on(2)[2].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED))
	# Un golpe que impone un control (el golpe de escudo aturde) no se marca como interrupción.
	_start_ability(drinker, potion, S + 290)
	var bash: AbilityTicks = _ability(&"shield_bash")
	_start_ability(attacker, bash, S + 300 - bash.cast_ticks)
	attacker.forget_swing()
	_tick(S + 300)
	assert_eq(combat.action, CombatState.Action.STUN, "el control ya corta lo que hacía")
	assert_false(_hits_on(2)[3].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "sin bit 5")


# --- Muestra antigua del bloqueo --------------------------------------------------------------

func test_the_old_block_sample_does_not_count_after_a_released_revive_or_an_interrupted_potion() -> void:
	# El atacante ve 10 ticks atrás; la víctima bloqueaba hasta S - 8 (lo que ve el atacante).
	var attacker: Combatant = _rewinding_attacker(1, Vector3.ZERO, 0.0, 10)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	for tick: int in range(S - 30, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		var flags: int = EntityRecord.FLAG_GROUNDED
		if tick <= S - 8:
			flags |= ActionMachine.DEFENSE_BLOCKING
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI, flags)
	CombatFixture.start_light_active(attacker, S)
	var combat: CombatState = _combat_of(victim)
	# Control: soltó el escudo sin más (NONE con el action_tick del bloqueo): lo que veía el atacante vale.
	CombatFixture.start_block(victim, S - 30)
	combat.action = CombatState.Action.NONE
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED, "soltar el escudo sin más sigue contando")
	# REVIVE empezado en S - 6 y soltado en S - 4: NONE con el action_tick del REVIVE (posterior a view_tick).
	ActionMachine.impose_interact(combat, S - 6, CombatState.Action.REVIVE)
	var release := PlayerInput.new()
	release.tick = S - 4
	ActionMachine.step(combat, release, true)
	assert_eq([combat.action, combat.action_tick], [CombatState.Action.NONE, S - 6], "soltó INTERACT")
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "un REVIVE soltado no conserva el bloqueo de antes")
	# Una poción empezada en S - 6 e interrumpida en S - 3: NONE con el action_tick de la poción.
	_start_ability(victim, _ability(&"potion_health"), S - 6)
	ActionMachine.impose_interrupt(combat, S - 3)
	assert_eq([combat.action, combat.action_tick], [CombatState.Action.NONE, S - 6], "interrumpida")
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "una poción interrumpida tampoco")


# --- Historial y publicación de la ranura 2 ---------------------------------------------------

func test_the_second_weapon_slot_never_reaches_the_history_as_a_block() -> void:
	await _start_server()
	var player: int = _fake(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0)
	var entity: NetEntity = _server.get_registry().get_entity(player)
	var character: PlayerCharacter = entity.get_character()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	# Arco en la ranura 1 y espada y escudo en la 2, la activa (como tras un cambio de arma).
	character.combat.weapon_id = sword
	character.combat.alt_weapon_id = bow
	character.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	CombatDirector.commit_state(character)
	await _step(3)
	var s: int = _server.get_tick()
	assert_true(character.combat.is_second_slot(), "lleva la ranura 2")
	var record_bytes := PackedByteArray()
	entity.encode_record(record_bytes, 0)
	var record: EntityRecord = EntityRecord.decode_from(record_bytes, 0, entity.kind)
	assert_true(record.is_second_slot(), "el registro del snapshot publica el bit 3 (ranura 2)")
	var flags: int = _server.get_history().get_flags(player, s)
	assert_true(flags >= 0, "el historial tiene el tick")
	assert_eq(flags & ActionMachine.DEFENSE_BLOCKING, 0, "sin bloquear, el historial no tiene el bit 3")
	assert_eq(_server_combatant(player).frozen.flags & ActionMachine.DEFENSE_BLOCKING, 0, "ni la muestra congelada")
	assert_true((flags & EntityRecord.FLAG_GROUNDED) != 0, "los bits 0-2 sí entran")
	# El SPAWN ajeno enseña las dos armas y la ranura activa (las armas se ven), no lo privado.
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(entity.encode_spawn(s, false))
	if assert_not_null(spawn, "SPAWN ajeno"):
		assert_eq(spawn.state.combat.weapon_id, sword)
		assert_eq(spawn.state.combat.alt_weapon_id, bow, "la otra arma")
		assert_true(spawn.state.combat.is_second_slot(), "y la ranura activa")


# --- Vano de la puerta cerrada ----------------------------------------------------------------

func test_from_inside_a_closed_gate_nobody_hits_out_and_nobody_is_hit() -> void:
	var gate: FortGate = (load(GATE_SCENE) as PackedScene).instantiate() as FortGate
	_world.add_child(gate)
	gate.set_state(VARDHEIM, false)
	await wait_physics_frames(2)
	# El dueño (Vardheim) con los pies en el vano (el pecho dentro de la caja de vista de 0,5 m), mirando al
	# oeste; un enemigo fuera, a 1,5 m, mirando al este.
	var owner: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, 0.5), PI * 0.5)
	var enemy: Combatant = _body(2, SOLMARCH, Vector3(-1.5, 0.0, 0.5), -PI * 0.5)
	CombatFixture.start_light_active(owner, S)
	CombatFixture.start_light_active(enemy, S)
	_tick()
	assert_eq(_hits_on(2).size(), 0, "desde dentro del vano no se golpea hacia fuera")
	assert_eq(_hits_on(1).size(), 0, "ni se recibe")
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	assert_false(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, 0.5), Vector3(-1.5, 0.9, 0.5)),
			"un rayo que empieza dentro de la caja choca en su origen")
	# Con la puerta rota no hay caja: los dos golpes entran.
	gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	owner.forget_swing()
	enemy.forget_swing()
	CombatFixture.start_light_active(owner, S + 100)
	CombatFixture.start_light_active(enemy, S + 100)
	_tick(S + 100)
	assert_eq(_hits_on(2).size(), 1, "rota, el dueño golpea")
	assert_eq(_hits_on(1).size(), 1, "y el enemigo también")
