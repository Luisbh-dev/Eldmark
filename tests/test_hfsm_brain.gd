extends TestCase
## Pruebas de [HfsmBrain] y del paso 0 del tick (MUN-07, MUN-08; docs/fuerte.md 4.2): REPOSO → ALERTA → COMBATE,
## percepción por radio, cono y línea de visión, la misma secuencia de estados con la misma semilla, las fichas de
## ataque, los que rodean, la correa con regreso regenerado e inmune, la alerta de grupo y el grito, los refuerzos del
## Capitán, el aviso TELEGRAPH y el golpe imbloqueable, y el registro de depuración. Casi todo sobre el suelo plano
## de [ZoneFixture] con PNJ sueltos; el servidor los avanza deprisa con un [FortressFixture.Stepper].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const STATE_REST: int = HfsmBrain.State.REST
const STATE_ALERT: int = HfsmBrain.State.ALERT
const STATE_COMBAT: int = HfsmBrain.State.COMBAT
const STATE_RETURN: int = HfsmBrain.State.RETURN

var _rig: NpcRig = null
var _next_seed: int = 100


func before_each() -> void:
	_rig = NpcRig.new()
	_next_seed = 100


func after_each() -> void:
	if _rig != null:
		await _rig.stop()
	_rig = null


# --- Ayudantes --------------------------------------------------------------------------------

## Un PNJ de [param definition_id] suelto (sin generador) del bando [param realm] en [param position] mirando a
## [param yaw]. Devuelve su net_id.
func _lone(definition_id: StringName, realm: int, position: Vector3, yaw: float = 0.0,
		group: StringName = &"", route: PackedVector3Array = PackedVector3Array(), rng_seed: int = -1) -> int:
	var definition: NpcDefinition = NpcCatalog.get_definition(definition_id)
	var brain := HfsmBrain.new(rng_seed if rng_seed >= 0 else _take_seed())
	var net_id: int = _rig.server.add_npc(brain, definition.display_name, realm, position, yaw, false, definition)
	brain.bind(_rig.npcs().get_world(), _rig.entity(net_id), _rig.combatant(net_id), definition, position, yaw,
			route, group)
	return net_id


func _take_seed() -> int:
	_next_seed += 1
	return _next_seed


func _brain(net_id: int) -> HfsmBrain:
	return _rig.npcs().get_brain(net_id) if _rig.npcs().get_brain(net_id) != null else _loose_brain(net_id)


# Los PNJ sueltos no están en el sistema: su cerebro se busca en el servidor.
func _loose_brain(net_id: int) -> HfsmBrain:
	return _rig.server._npcs.get(net_id) as HfsmBrain


func _flat_with_no_spawners() -> void:
	await _rig.start_flat(tree)


func _idle_player(realm: int, position: Vector3, yaw: float = 0.0) -> int:
	return _rig.add_player(realm, position, null, yaw)


func _is_attack(action: int) -> bool:
	return action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY \
			or action == CombatState.Action.CHARGE


func _states(net_id: int) -> Array[int]:
	var states: Array[int] = []
	for entry: Vector2i in _brain(net_id).get_state_log():
		states.append(entry.y)
	return states


# --- Percepción -------------------------------------------------------------------------------

func test_a_hollow_goes_from_rest_to_alert_to_combat_when_a_player_walks_into_view() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3(0.0, 0.0, 0.0), 0.0)
	await _rig.advance(30)
	assert_eq(_brain(hollow).state, STATE_REST, "sin nadie cerca, en reposo")
	# El Hueco mira hacia -Z (yaw 0): a 10 m delante, dentro de su radio de 16 m y de su cono.
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -10.0))
	await _rig.advance(15)
	assert_eq(_brain(hollow).state, STATE_ALERT, "lo ve: alerta, y todavía no ataca")
	await _rig.advance(90)
	assert_eq(_brain(hollow).state, STATE_COMBAT, "tras reaccionar, combate")
	assert_eq(_states(hollow), [STATE_REST, STATE_ALERT, STATE_COMBAT] as Array[int],
			"la secuencia es reposo, alerta y combate")


func test_perception_needs_the_radius_the_cone_and_a_clear_line_of_sight() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		# Un muro delante del Hueco que está en x = 30 y otro tras el de x = 150.
		NpcRig.add_wall(world, Vector3(30.0, 1.5, -4.0), Vector3(12.0, 3.0, 0.5))
		NpcRig.add_wall(world, Vector3(150.0, 1.5, 2.0), Vector3(12.0, 3.0, 0.5)))
	# Cada Hueco en su rincón, a 60 m de los demás para no oírse entre sí.
	var in_front: int = _lone(&"hollow", 0, Vector3(-150.0, 0.0, 0.0), 0.0)
	var too_far: int = _lone(&"hollow", 0, Vector3(-90.0, 0.0, 0.0), 0.0)
	var behind: int = _lone(&"hollow", 0, Vector3(-30.0, 0.0, 0.0), 0.0)
	var behind_wall: int = _lone(&"hollow", 0, Vector3(30.0, 0.0, 0.0), 0.0)
	var heard: int = _lone(&"hollow", 0, Vector3(90.0, 0.0, 0.0), 0.0)
	var heard_through_wall: int = _lone(&"hollow", 0, Vector3(150.0, 0.0, 0.0), 0.0)
	_idle_player(VARDHEIM, Vector3(-150.0, 0.0, -10.0))     # delante, a 10 m
	_idle_player(SOLMARCH, Vector3(-90.0, 0.0, -20.0))      # delante, pero a 20 m (radio 16)
	_idle_player(VARDHEIM, Vector3(-30.0, 0.0, 8.0))        # detrás, a 8 m (fuera del oído de 4 m)
	_idle_player(SOLMARCH, Vector3(30.0, 0.0, -10.0))       # delante, a 10 m, con un muro en medio
	_idle_player(VARDHEIM, Vector3(90.0, 0.0, 3.0))         # detrás, a 3 m: dentro del oído
	_idle_player(SOLMARCH, Vector3(150.0, 0.0, 4.0))        # detrás, a 4 m, con un muro en medio
	await _rig.advance(120)
	assert_ne_int(_brain(in_front).state, STATE_REST, "el de delante lo ve")
	assert_eq(_brain(too_far).state, STATE_REST, "a 20 m está fuera del radio de visión")
	assert_eq(_brain(behind).state, STATE_REST, "a su espalda y a 8 m no lo ve")
	assert_eq(_brain(behind_wall).state, STATE_REST, "con un muro delante no lo ve")
	assert_ne_int(_brain(heard).state, STATE_REST, "a su espalda pero a 3 m lo nota")
	assert_eq(_brain(heard_through_wall).state, STATE_REST, "ni el oído atraviesa un muro")


func assert_ne_int(actual: int, unexpected: int, message: String = "") -> bool:
	return assert_true(actual != unexpected, "%s (era %d)" % [message, actual])


func test_a_safe_player_in_their_own_camp_is_not_a_target_and_a_protected_one_neither() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"vardheim", Vector3(0.0, 0.0, -10.0), 8.0))
	var hollow: int = _lone(&"hollow", 0, Vector3(0.0, 0.0, 0.0), 0.0)
	var safe: int = _idle_player(VARDHEIM, Vector3(0.0, 0.0, -9.0))
	await _rig.advance(90)
	assert_eq(_brain(hollow).state, STATE_REST, "no persigue a quien no puede tocar: está a salvo en su zona segura")
	# Fuera de la zona segura sí.
	_rig.server.teleport(safe, Vector3(0.0, 0.0, -0.5))
	await _rig.advance(30)
	assert_ne_int(_brain(hollow).state, STATE_REST, "fuera de la zona segura, ya es un objetivo")


# --- Determinismo -----------------------------------------------------------------------------

## Un Hueco con la semilla [param hollow_seed] contra un bot de combate con la semilla [param bot_seed]
## durante [param ticks] ticks. Devuelve la secuencia de estados y el estado final (posiciones y vidas).
func _duel(hollow_seed: int, bot_seed: int, ticks: int) -> Dictionary:
	var rig := NpcRig.new()
	await rig.start_flat(tree)
	var definition: NpcDefinition = NpcCatalog.get_definition(&"hollow")
	var brain := HfsmBrain.new(hollow_seed)
	var hollow: int = rig.server.add_npc(brain, "Hueco", 0, Vector3.ZERO, 0.0, false, definition)
	brain.bind(rig.npcs().get_world(), rig.entity(hollow), rig.combatant(hollow), definition, Vector3.ZERO, 0.0)
	var bot: int = rig.add_player(VARDHEIM, Vector3(0.0, 0.0, -9.0),
			BotBrain.new(bot_seed, BotBrain.Pattern.COMBAT), 0.0)
	await rig.advance(ticks)
	var result: Dictionary = {
		"log": brain.get_state_log().duplicate(),
		"hollow_position": rig.entity(hollow).get_position(),
		"bot_position": rig.entity(bot).get_position(),
		"hollow_health": rig.combatant(hollow).health,
		"bot_health": rig.combatant(bot).health,
	}
	await rig.stop()
	return result


func test_the_same_seed_gives_the_same_state_sequence_against_a_bot() -> void:
	var first: Dictionary = await _duel(7, 3, 1500)
	var second: Dictionary = await _duel(7, 3, 1500)
	assert_true((first["log"] as Array).size() >= 3, "la pelea recorre varios estados (%s)" % [first["log"]])
	assert_eq(first["log"], second["log"], "la misma secuencia de estados, con los mismos ticks")
	assert_eq(first["hollow_position"], second["hollow_position"], "y la misma posición final")
	assert_eq(first["bot_position"], second["bot_position"])
	assert_eq(first["hollow_health"], second["hollow_health"], "y las mismas vidas")
	assert_eq(first["bot_health"], second["bot_health"])
	# Con otra semilla del PNJ cambian sus reacciones: la secuencia con sus ticks no es la misma.
	var other: Dictionary = await _duel(8, 3, 1500)
	assert_true(other["log"] != first["log"] or other["hollow_health"] != first["hollow_health"],
			"otra semilla, otra pelea")


# --- Paso 0 del tick --------------------------------------------------------------------------

func test_brains_think_before_anyone_is_simulated_in_the_tick() -> void:
	await _flat_with_no_spawners()
	var seen: Dictionary = {"checks": 0, "bad": 0}
	var rig: NpcRig = _rig
	# Un PNJ espía, con el id más alto: mira a todos los cuerpos al empezar su turno de cada tick.
	var other: int = _idle_player(VARDHEIM, Vector3(5.0, 0.0, 0.0))
	var spy_brain := CombatFixture.ScriptBrain.new(1)
	spy_brain.script_fn = func(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		for entity: NetEntity in rig.server.get_registry().get_sorted():
			if entity.get_character() != null:
				seen["checks"] += 1
				if entity.get_character().last_input_tick != tick - 1 and tick > 5:
					seen["bad"] += 1
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		return input
	var spy: int = _rig.server.add_npc(spy_brain, "Espía", 0, Vector3(-5.0, 0.0, 0.0), 0.0)
	assert_true(spy > other, "el espía tiene el id más alto")
	await _rig.advance(60)
	assert_true(seen["checks"] > 100, "el espía ha mirado a todos (%d)" % seen["checks"])
	assert_eq(seen["bad"], 0, "ningún cuerpo estaba ya simulado en el tick: los cerebros ven el estado tras s - 1")


func test_a_brain_thinks_every_six_ticks_and_repeats_its_plan_in_between() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	await _rig.advance(120)
	assert_true(brain.get_think_count() >= 19 and brain.get_think_count() <= 22,
			"unos 20 pensamientos en 120 ticks (%d)" % brain.get_think_count())
	assert_eq(HfsmBrain.THINK_INTERVAL_TICKS, 6)


# --- Fichas ------------------------------------------------------------------------------------

## Cuatro guardias de Solmarch rodean a un jugador de Vardheim al que se cura en cada tick. Devuelve lo que se mide.
func _four_guards_against_one(ticks: int) -> Dictionary:
	await _flat_with_no_spawners()
	var guards: Array[int] = []
	for index: int in 4:
		var angle: float = TAU * float(index) / 4.0
		guards.append(_lone(&"realm_guard", SOLMARCH, Vector3(cos(angle), 0.0, sin(angle)) * 7.0, PI * 0.5 - angle,
				&"guardias"))
	var player: int = _idle_player(VARDHEIM, Vector3.ZERO)
	var combatant: Combatant = _rig.combatant(player)
	var stats: Dictionary = {"max": 0, "two": 0, "attack_ticks": 0, "ring": [], "damage": 0}
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		if combatant.health < combatant.max_health:
			stats["damage"] += combatant.max_health - combatant.health
		combatant.health = combatant.max_health
		var attackers: int = 0
		for guard: int in guards:
			var guard_state: CombatState = _rig.character(guard).combat
			if _is_attack(guard_state.action):
				attackers += 1
			elif _brain(guard).state == STATE_COMBAT and not _rig.npcs().get_world().tokens.holds(player, guard, _tick) \
					and guard_state.action == CombatState.Action.NONE:
				var distance: float = _rig.entity(guard).get_position().distance_to(_rig.entity(player).get_position())
				(stats["ring"] as Array).append(distance)
		stats["max"] = maxi(stats["max"], attackers)
		if attackers >= 2:
			stats["two"] += 1
		if attackers > 0:
			stats["attack_ticks"] += 1)
	await _rig.advance(ticks)
	stats["denied"] = _rig.npcs().get_world().tokens.get_stats()["denied"]
	return stats


func test_four_guards_against_one_player_never_attack_more_than_two_at_once() -> void:
	var stats: Dictionary = await _four_guards_against_one(2400)
	assert_true(stats["max"] <= 2, "nunca más de 2 atacan a la vez (máximo visto: %d)" % stats["max"])
	assert_true(stats["max"] >= 2, "pero sí llegan a atacar dos a la vez: la prueba mide algo")
	assert_true(stats["two"] > 100, "y lo hacen a menudo (%d ticks con dos)" % stats["two"])
	assert_true(stats["damage"] > 300, "el jugador recibe daño (%d)" % stats["damage"])
	assert_true(stats["denied"] > 10, "las fichas se deniegan a los demás (%d)" % stats["denied"])


func test_the_ones_without_a_token_circle_the_player_at_three_to_four_meters() -> void:
	var stats: Dictionary = await _four_guards_against_one(1800)
	var ring: Array = stats["ring"]
	assert_true(ring.size() > 200, "hay muchas muestras de PNJ esperando su turno (%d)" % ring.size())
	var sum: float = 0.0
	var inside: int = 0
	for distance: float in ring:
		sum += distance
		if distance >= 2.5 and distance <= 4.8:
			inside += 1
	assert_near(sum / float(ring.size()), 3.5, 0.6, "a unos 3,5 m de media")
	assert_true(float(inside) / float(ring.size()) > 0.6, "y la mayoría de las veces dentro de 2,5 a 4,8 m")


func test_attack_tokens_are_released_when_the_npc_dies_or_loses_the_target() -> void:
	var tokens := AttackTokens.new()
	assert_true(tokens.try_claim(9, 1, 100))
	assert_true(tokens.try_claim(9, 2, 100))
	assert_false(tokens.try_claim(9, 3, 100), "la tercera ficha se deniega")
	assert_true(tokens.try_claim(9, 1, 110), "quien ya la tiene la conserva")
	assert_eq(tokens.count(9, 110), 2)
	tokens.release_all(1)
	assert_true(tokens.try_claim(9, 3, 111), "al soltar queda una libre")
	assert_false(tokens.try_claim(9, 4, 111))
	# Una ficha caduca sola.
	assert_true(tokens.try_claim(9, 4, 111 + AttackTokens.TTL_TICKS + 1), "caducadas, se reparten otra vez")
	assert_false(tokens.renew(9, 2, 111 + AttackTokens.TTL_TICKS + 1), "no se renueva una caducada")
	assert_true(tokens.try_claim(10, 1, 111), "contra otro objetivo es otra cuenta")


# --- Correa ------------------------------------------------------------------------------------

func test_the_leash_sends_the_npc_back_regenerated_and_immune() -> void:
	await _flat_with_no_spawners()
	var post := Vector3(0.0, 0.0, 0.0)
	var hollow: int = _lone(&"hollow", 0, post, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	var combatant: Combatant = _rig.combatant(hollow)
	# Un jugador que huye hacia el oeste a la velocidad de carrera (un poco más que el Hueco, que va al 85 %).
	var runner := CombatFixture.ScriptBrain.new(1)
	var running: Dictionary = {"run": false}
	runner.script_fn = func(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI * 0.5 if running["run"] else yaw
		input.move = Vector2(0.0, 1.0) if running["run"] else Vector2.ZERO
		return input
	var player: int = _rig.add_player(VARDHEIM, Vector3(0.0, 0.0, -9.0), runner, 0.0)
	await _rig.advance(150)
	assert_eq(brain.state, STATE_COMBAT, "se ha enganchado al jugador")
	combatant.health = roundi(float(combatant.max_health) * 0.25)
	var leash: float = NpcCatalog.get_definition(&"hollow").leash_radius
	var farthest: Dictionary = {"distance": 0.0}
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		farthest["distance"] = maxf(farthest["distance"],
				_rig.entity(hollow).get_position().distance_to(post)))
	running["run"] = true
	var returned: bool = await _rig.advance_until(func() -> bool: return brain.state == STATE_RETURN, 1200)
	if not assert_true(returned, "pasada la correa, regresa (estado %s)" % HfsmBrain.state_name(brain.state)):
		return
	var now: int = _rig.server.get_tick()
	assert_true(combatant.is_protected(now), "el regreso es inmune")
	assert_true((combatant.status_bits(now) & NetMessages.STATUS_PROTECTED) != 0, "y los clientes lo ven protegido")
	assert_true(combatant.health < combatant.max_health, "todavía no está regenerado a medio camino")
	assert_true(farthest["distance"] <= leash + 4.0, "no se alejó mucho más que su correa (%.1f m de %.1f)"
			% [farthest["distance"], leash])
	assert_true(farthest["distance"] >= leash - 1.0, "y llegó hasta ella (%.1f m)" % farthest["distance"])
	var home: bool = await _rig.advance_until(func() -> bool: return brain.state != STATE_RETURN, 2400)
	assert_true(home, "llega a su puesto")
	assert_eq(brain.state, STATE_REST, "y se queda en reposo")
	assert_eq(combatant.health, combatant.max_health, "regenerado del todo")
	assert_false(combatant.is_protected(_rig.server.get_tick()), "y ya no es inmune")
	assert_true(_rig.entity(hollow).get_position().distance_to(post) < 2.5, "en su puesto")
	assert_true(player > 0)


# --- Atacado desde lejos (revisión de la fase 4, lente «trampas») ---------------------------------------

## [param count] arqueros de Vardheim con el arco en z = [param z] (separados 3 m) que disparan el ligero a
## [param target_id] (con la caída compensada) dos ticks de cada 40, escalonados. Devuelve sus net_id.
func _archers(count: int, z: float, target_id: int) -> Array[int]:
	var archers: Array[int] = []
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	var bow: int = CombatCatalog.weapon_id(&"bow")
	for index: int in count:
		var offset: int = index * 13
		var archer := CombatFixture.ScriptBrain.new(1)
		archer.script_fn = func(tick: int, position: Vector3, yaw: float) -> PlayerInput:
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = yaw
			var target: NetEntity = _rig.entity(target_id) if _rig != null and _rig.server != null else null
			if target == null:
				return input
			var muzzle: Vector3 = AimRay.muzzle(position)
			var center: Vector3 = target.get_position() + Vector3(0.0, 0.9, 0.0)
			var point: Vector3 = muzzle + Ballistics.solve_lead(muzzle, center, Vector3.ZERO, 45.0, arrow.gravity) \
					* muzzle.distance_to(center)
			var look: Vector2 = AimRay.look_for(position, point, false)
			input.look_yaw = look.x
			input.look_pitch = look.y
			if (tick + offset) % 40 < 2:
				input.buttons |= PlayerInput.PRIMARY
			return input
		var x: float = (float(index) - float(count - 1) * 0.5) * 3.0
		var net_id: int = _rig.add_player(VARDHEIM, Vector3(x, 0.0, z), archer, PI)
		assert_true(_rig.server.get_combat().set_weapon(_rig.combatant(net_id), bow), "con el arco")
		archers.append(net_id)
	return archers


func _damage_taken(net_ids: Array[int]) -> int:
	var total: int = 0
	for net_id: int in net_ids:
		total += _rig.combatant(net_id).max_health - _rig.combatant(net_id).health
	return total


## Antes, un PNJ golpeado desde más allá de su radio de pérdida (28 m el Hueco; la flecha llega a unos 90 m) entraba
## en combate sin objetivo, se quedaba quieto y a los 3 s volvía a su puesto curado del todo, y vuelta a empezar: con
## pocos arqueros no se le podía matar y con muchos moría sin moverse ni hacer daño. Ahora va a por quien le dispara.
func test_an_npc_shot_from_beyond_its_lose_radius_goes_for_the_archers() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	var lose: float = NpcCatalog.get_definition(&"hollow").lose_radius
	assert_true(33.0 > lose, "los arqueros, más allá de su radio de pérdida (%.0f m)" % lose)
	var archers: Array[int] = _archers(3, -33.0, hollow)
	var hit: bool = await _rig.advance_until(func() -> bool:
		return _rig.combatant(hollow).health < _rig.combatant(hollow).max_health, 300)
	if not assert_true(hit, "las flechas le dan"):
		return
	var rests_before: int = _states(hollow).count(STATE_REST)
	var fought_back: bool = await _rig.advance_until(func() -> bool: return _damage_taken(archers) > 0, 1200)
	var position: Vector3 = _rig.entity(hollow).get_position()
	assert_true(fought_back, "llega hasta los arqueros y les hace daño (está en %s, %s)"
			% [position, HfsmBrain.state_name(brain.state)])
	assert_true(position.z < -25.0, "ha ido a por ellos (z = %.1f)" % position.z)
	assert_eq(_states(hollow).count(STATE_REST), rests_before, "sin volver a su puesto curado entre medias")
	assert_eq(_states(hollow).count(STATE_RETURN), 0, "ni regresar: los arqueros están dentro de su correa")


## Si quien le dispara está más allá de su correa, lo persigue hasta ella y regresa inmune (no se queda quieto
## recibiendo flechas).
func test_an_npc_shot_from_beyond_its_leash_chases_to_the_leash_and_returns_immune() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	var leash: float = NpcCatalog.get_definition(&"hollow").leash_radius
	var archers: Array[int] = _archers(3, -55.0, hollow)
	var returned: bool = await _rig.advance_until(func() -> bool: return brain.state == STATE_RETURN, 1500)
	if not assert_true(returned, "pasada la correa, regresa (estado %s, en %s)"
			% [HfsmBrain.state_name(brain.state), _rig.entity(hollow).get_position()]):
		return
	assert_true(_rig.entity(hollow).get_position().length() >= leash - 1.0, "tras perseguirlos hasta su correa")
	assert_true(_rig.combatant(hollow).is_protected(_rig.server.get_tick()), "inmune mientras regresa")
	assert_eq(_damage_taken(archers), 0, "sin llegar a ellos")
	assert_true(_rig.combatant(hollow).is_alive())


## Revisión de la fase 4 (trampas): el registro de estados de un PNJ está acotado (antes crecía sin límite: un Hueco
## que patrulla suma unas 10 transiciones por minuto durante días).
func test_the_state_log_keeps_only_the_latest_transitions() -> void:
	var brain := HfsmBrain.new(1)
	var transitions: int = HfsmBrain.STATE_LOG_MAX * 10
	for index: int in transitions:
		brain._enter(STATE_REST if index % 2 == 0 else HfsmBrain.State.PATROL, index)
	var entries: Array[Vector2i] = brain.get_state_log()
	assert_true(entries.size() >= HfsmBrain.STATE_LOG_MAX and entries.size() < HfsmBrain.STATE_LOG_MAX * 2,
			"entre el tope y el doble (%d)" % entries.size())
	assert_eq(entries[entries.size() - 1], Vector2i(transitions - 1, HfsmBrain.State.PATROL), "con la última")
	var contiguous: bool = true
	for index: int in range(1, entries.size()):
		contiguous = contiguous and entries[index].x == entries[index - 1].x + 1
	assert_true(contiguous, "y las anteriores seguidas, sin huecos")


# --- Alerta de grupo y grito -----------------------------------------------------------------------

func test_a_group_alert_wakes_the_nearby_members_and_not_the_far_ones() -> void:
	await _flat_with_no_spawners()
	var group: StringName = &"banda"
	var seen: int = _lone(&"hollow", 0, Vector3(0.0, 0.0, 0.0), 0.0, group)
	var near: int = _lone(&"hollow", 0, Vector3(20.0, 0.0, 0.0), PI, group)     # a 20 m, de espaldas
	var far: int = _lone(&"hollow", 0, Vector3(60.0, 0.0, 0.0), PI, group)      # a 60 m
	var other_group: int = _lone(&"hollow", 0, Vector3(10.0, 0.0, 12.0), PI, &"otra")
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	await _rig.advance(90)
	assert_eq(_brain(seen).state, STATE_COMBAT, "el que lo ve")
	assert_true(_brain(near).state == STATE_ALERT or _brain(near).state == STATE_COMBAT,
			"el del grupo a 20 m se entera aunque no lo vea")
	assert_eq(_brain(far).state, STATE_REST, "a 60 m no llega la alerta de 25 m")
	assert_eq(_brain(other_group).state, STATE_REST, "ni a otro grupo")


func test_the_captains_shout_reaches_the_hollows_of_the_fort_but_only_if_there_are_any() -> void:
	await _flat_with_no_spawners()
	var group: StringName = &"vado"
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0, group)
	var hollow: int = _lone(&"hollow", 0, Vector3(50.0, 0.0, 0.0), PI, group)   # a 50 m, de espaldas
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	await _rig.advance(120)
	assert_eq(_brain(captain).state, STATE_COMBAT)
	assert_true(_brain(hollow).state == STATE_ALERT or _brain(hollow).state == STATE_COMBAT,
			"el grito llega a 50 m, más allá de los 25 m de la alerta normal")


func test_the_captain_calls_two_hollows_at_half_health_only_if_hollows_remain() -> void:
	await _flat_with_no_spawners()
	var group: StringName = &"vado"
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0, group)
	var hollow: int = _lone(&"hollow", 0, Vector3(15.0, 0.0, 0.0), PI, group)
	var player: int = _idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	var captain_combatant: Combatant = _rig.combatant(captain)
	var hollows_before: int = _count_npcs_of(&"hollow")
	await _rig.advance(60)
	assert_eq(_count_npcs_of(&"hollow"), hollows_before, "con la vida llena no hay refuerzos")
	captain_combatant.health = roundi(float(captain_combatant.max_health) * 0.5) - 10
	await _rig.advance(40)
	assert_eq(_count_npcs_of(&"hollow"), hollows_before + 2, "al 50 %% de vida llegan dos Huecos más")
	await _rig.advance(40)
	assert_eq(_count_npcs_of(&"hollow"), hollows_before + 2, "y solo una vez")
	var reinforcement: NetEntity = null
	for entity: NetEntity in _rig.server.get_registry().get_sorted():
		if entity.kind == NetProtocol.EntityKind.NPC and entity.net_id > hollow and entity.net_id != captain \
				and entity.npc_def_id == NpcCatalog.number_of(&"hollow"):
			reinforcement = entity
	assert_not_null(reinforcement, "hay refuerzos")
	assert_true(reinforcement.get_position().distance_to(_rig.entity(captain).get_position()) < 8.0,
			"aparecen junto al Capitán")
	assert_true(_loose_brain(reinforcement.net_id) != null)
	assert_true(_loose_brain(reinforcement.net_id).state != STATE_REST, "y ya están alerta")
	assert_true(player > 0)


func test_the_captain_does_not_call_reinforcements_when_no_hollow_is_left() -> void:
	await _flat_with_no_spawners()
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0, &"vado")
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	var combatant: Combatant = _rig.combatant(captain)
	combatant.health = roundi(float(combatant.max_health) * 0.5) - 10
	await _rig.advance(120)
	assert_eq(_count_npcs_of(&"hollow"), 0, "sin Huecos vivos no hay refuerzos")


func _count_npcs_of(definition_id: StringName) -> int:
	var total: int = 0
	var number: int = NpcCatalog.number_of(definition_id)
	for entity: NetEntity in _rig.server.get_registry().get_sorted():
		if entity.kind == NetProtocol.EntityKind.NPC and entity.npc_def_id == number \
				and _rig.combatant(entity.net_id).is_alive():
			total += 1
	return total


# --- Golpe imbloqueable y telegrafiado ------------------------------------------------------------

func test_the_captain_telegraphs_the_unblockable_strike_and_a_block_does_not_stop_it() -> void:
	await _flat_with_no_spawners()
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0)
	var blocker: int = _rig.add_player(VARDHEIM, Vector3(0.0, 0.0, -2.2), _holding_block_brain(), PI)
	var blocker_combatant: Combatant = _rig.combatant(blocker)
	blocker_combatant.protected_until = 0
	var crush_id: int = CombatCatalog.attack_id(&"npc_captain_crush")
	var sweep_id: int = CombatCatalog.attack_id(&"npc_captain_sweep")
	var found: bool = await _rig.advance_until(func() -> bool:
		for event: NetMessages.EntityEvent in _rig.events_of(NetMessages.EntityEvent.Kind.HIT):
			if event.attack_id == crush_id and event.net_id == blocker:
				return true
		return blocker_combatant.is_dead(), 2400, 6)
	assert_true(found, "el Capitán acaba lanzando su golpe fuerte")
	var telegraphs: Array[NetMessages.EntityEvent] = _rig.events_of(NetMessages.EntityEvent.Kind.TELEGRAPH)
	if not assert_false(telegraphs.is_empty(), "el golpe fuerte se avisa con un TELEGRAPH"):
		return
	var crush: AttackTicks = CombatCatalog.attack(crush_id)
	var telegraph: NetMessages.EntityEvent = telegraphs[0]
	assert_eq(telegraph.net_id, captain, "del Capitán")
	assert_eq(telegraph.attack_id, crush_id)
	assert_eq(telegraph.shape, NetMessages.EntityEvent.SHAPE_SECTOR, "un sector")
	assert_eq(telegraph.radius_cm, roundi(crush.shape.range_m * 100.0), "con el alcance del golpe")
	assert_eq(telegraph.impact_in_ticks, crush.windup_ticks, "avisa toda la anticipación")
	assert_true(telegraph.impact_in_ticks >= 42, "y es legible: al menos 0,7 s")
	# El golpe llega a quien bloquea, con el daño completo y sin la marca de bloqueo.
	var crush_hit: NetMessages.EntityEvent = null
	var sweep_hits: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _rig.events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id != blocker:
			continue
		if event.attack_id == crush_id and crush_hit == null:
			crush_hit = event
		elif event.attack_id == sweep_id:
			sweep_hits.append(event)
	if assert_not_null(crush_hit, "el golpe imbloqueable acierta"):
		assert_false(crush_hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "sin bloquear")
		assert_false(crush_hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), "ni parar")
		assert_eq(crush_hit.amount, crush.base_damage, "con todo su daño")
		assert_true(crush_hit.tick - telegraph.tick >= crush.windup_ticks, "no antes de que acabe la anticipación")
	assert_true(sweep_hits.size() >= 1, "antes hubo barridos")
	for sweep: NetMessages.EntityEvent in sweep_hits:
		assert_true(sweep.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "y el escudo los paró")


func _holding_block_brain() -> BotBrain:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		input.buttons = PlayerInput.BLOCK
		return input
	return brain


func test_a_bot_that_blocks_a_quarter_second_after_seeing_a_heavy_starts_blocks_every_hollow_heavy() -> void:
	await _flat_with_no_spawners()
	await _check_every_heavy_is_blocked(&"hollow", 0, &"npc_hollow_slam")


func test_a_bot_that_blocks_a_quarter_second_after_seeing_a_heavy_starts_blocks_every_guard_heavy() -> void:
	await _flat_with_no_spawners()
	await _check_every_heavy_is_blocked(&"realm_guard", SOLMARCH, &"npc_guard_bash")


## Un PNJ de [param definition_id] que solo ataca con el golpe fuerte contra un jugador que lo bloquea 550 ms
## después de verlo empezar: todos los golpes fuertes (de [param attack_name]) tienen que llegar bloqueados.
func _check_every_heavy_is_blocked(definition_id: StringName, realm: int, attack_name: StringName) -> void:
	var definition: NpcDefinition = NpcCatalog.get_definition(definition_id).duplicate() as NpcDefinition
	definition.heavy_chance = 1.0
	definition.block_chance = 0.0
	var brain := HfsmBrain.new(5)
	var npc: int = _rig.server.add_npc(brain, "PNJ", realm, Vector3.ZERO, 0.0, false, definition)
	brain.bind(_rig.npcs().get_world(), _rig.entity(npc), _rig.combatant(npc), definition, Vector3.ZERO, 0.0)
	# Con un RTT de 200 ms (--net-sim=rtt=200) el jugador ve la preparación 100 ms después (la mitad del RTT) más unos
	# 100 ms de retardo de interpolación, reacciona 250 ms más tarde y su entrada tarda otros 100 ms en llegar al
	# servidor: 550 ms, 33 ticks.
	var delay: int = 33
	var watcher := {"seen_at": -1, "last_action_tick": -1}
	var rig: NpcRig = _rig
	var player_brain := CombatFixture.ScriptBrain.new(1)
	player_brain.script_fn = func(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		var state: CombatState = rig.character(npc).combat
		if state.action == CombatState.Action.HEAVY and state.action_tick != watcher["last_action_tick"]:
			watcher["last_action_tick"] = state.action_tick
			watcher["seen_at"] = tick
		var since: int = tick - int(watcher["seen_at"])
		if watcher["seen_at"] >= 0 and since >= delay and since < delay + 60:
			input.buttons = PlayerInput.BLOCK
		return input
	var player_realm: int = VARDHEIM if realm != VARDHEIM else SOLMARCH
	var player: int = _rig.add_player(player_realm, Vector3(0.0, 0.0, -2.0), player_brain, PI)
	var combatant: Combatant = _rig.combatant(player)
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		combatant.health = combatant.max_health
		combatant.protected_until = 0)
	await _rig.advance(2400)
	var heavy_id: int = CombatCatalog.attack_id(attack_name)
	var heavies: int = 0
	var blocked: int = 0
	for event: NetMessages.EntityEvent in _rig.events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.attack_id == heavy_id and event.net_id == player:
			heavies += 1
			if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED):
				blocked += 1
	assert_true(heavies >= 4, "%s lanza varios golpes fuertes (%d)" % [definition_id, heavies])
	assert_eq(blocked, heavies, "y el jugador, con 550 ms de retraso, los bloquea todos")
	assert_true(CombatCatalog.attack(heavy_id).windup_ticks > delay + 6, "la anticipación (%d ticks) deja sitio a esa reacción"
			% CombatCatalog.attack(heavy_id).windup_ticks)


# --- Depuración -------------------------------------------------------------------------------

func test_npc_debug_writes_state_target_and_path_every_second() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -9.0))
	var lines: PackedStringArray = PackedStringArray()
	_rig.npcs().log_sink = func(line: String) -> void: lines.append(line)
	# Apagado de entrada: sin líneas.
	await _rig.advance(130)
	assert_true(lines.is_empty(), "sin el comando no se escribe nada")
	assert_false(_rig.npcs().is_debug_enabled())
	assert_eq(_rig.server.console_command("npc_debug on"), "Depuración de PNJ activada")
	assert_true(_rig.npcs().is_debug_enabled())
	await _rig.advance(125)
	assert_true(lines.size() >= 2, "una línea por PNJ y segundo (%d)" % lines.size())
	assert_true(lines[0].contains("Hueco") and lines[0].contains("estado=") and lines[0].contains("objetivo=")
			and lines[0].contains("ruta=") and lines[0].contains("vida="), lines[0])
	assert_true(lines[lines.size() - 1].contains("estado=combate"), "dice el estado: %s" % lines[lines.size() - 1])
	# Por la red (el id 12), con los datos de DebugCommand.
	var peer := ServerPeer.new(3)
	assert_eq(_rig.server.get_commands().execute_network(peer, NetProtocol.DEBUG_NPC_DEBUG, PackedByteArray([0])),
			CommandRegistry.Result.OK, "apagar por la red")
	assert_false(_rig.npcs().is_debug_enabled())
	assert_eq(_rig.server.get_commands().execute_network(peer, NetProtocol.DEBUG_NPC_DEBUG, PackedByteArray([2])),
			CommandRegistry.Result.BAD_ARGUMENTS, "un valor que no es 0 ni 1 no vale")
	assert_eq(_rig.server.get_commands().execute_network(peer, NetProtocol.DEBUG_NPC_DEBUG, PackedByteArray([1])),
			CommandRegistry.Result.OK, "encender por la red")
	assert_true(_rig.npcs().is_debug_enabled())
	assert_true(hollow > 0)
	# Los del protocolo 6: 13 y 14 llegaron con H3a; 15 y 16, con H3c (docs/habilidades.md §7.1). Los cuatro de la
	# progresión del protocolo 7 (40 a 43), con progresion.md P5d.
	assert_eq(_rig.server.get_commands().missing_network_commands(), PackedStringArray(),
			"con npc_debug ya están todos los comandos de red")
