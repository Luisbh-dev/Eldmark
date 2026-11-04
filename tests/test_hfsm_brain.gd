extends TestCase
## Tests for [HfsmBrain] and for step 0 of the tick (MUN-07, MUN-08; docs/fuerte.md 4.2): REST → ALERT → COMBAT,
## perception by radius, cone and line of sight, the same state sequence with the same seed, attack
## tokens, flankers, the leash with regenerated and immune return, the group alert and the shout, the
## Captain's reinforcements, the TELEGRAPH alert and the unblockable hit, and the debug log. Almost all on the flat
## ground of [ZoneFixture] with loose NPCs; the server advances them quickly with a [FortressFixture.Stepper].

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


# --- Helpers ----------------------------------------------------------------------------------

## A loose NPC (no spawner) of [param definition_id] on side [param realm] at [param position] facing
## [param yaw]. Returns its net_id.
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


# Loose NPCs are not in the system: their brain is looked up on the server.
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


# --- Perception -------------------------------------------------------------------------------

func test_a_hollow_goes_from_rest_to_alert_to_combat_when_a_player_walks_into_view() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3(0.0, 0.0, 0.0), 0.0)
	await _rig.advance(30)
	assert_eq(_brain(hollow).state, STATE_REST, "with nobody nearby, at rest")
	# The Hollow faces -Z (yaw 0): 10 m ahead, within its 16 m radius and its cone.
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -10.0))
	await _rig.advance(15)
	assert_eq(_brain(hollow).state, STATE_ALERT, "it sees them: alert, and does not attack yet")
	await _rig.advance(90)
	assert_eq(_brain(hollow).state, STATE_COMBAT, "after reacting, combat")
	assert_eq(_states(hollow), [STATE_REST, STATE_ALERT, STATE_COMBAT] as Array[int],
			"the sequence is rest, alert and combat")


func test_perception_needs_the_radius_the_cone_and_a_clear_line_of_sight() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		# A wall in front of the Hollow at x = 30 and another behind the one at x = 150.
		NpcRig.add_wall(world, Vector3(30.0, 1.5, -4.0), Vector3(12.0, 3.0, 0.5))
		NpcRig.add_wall(world, Vector3(150.0, 1.5, 2.0), Vector3(12.0, 3.0, 0.5)))
	# Each Hollow in its own corner, 60 m from the others so they do not hear each other.
	var in_front: int = _lone(&"hollow", 0, Vector3(-150.0, 0.0, 0.0), 0.0)
	var too_far: int = _lone(&"hollow", 0, Vector3(-90.0, 0.0, 0.0), 0.0)
	var behind: int = _lone(&"hollow", 0, Vector3(-30.0, 0.0, 0.0), 0.0)
	var behind_wall: int = _lone(&"hollow", 0, Vector3(30.0, 0.0, 0.0), 0.0)
	var heard: int = _lone(&"hollow", 0, Vector3(90.0, 0.0, 0.0), 0.0)
	var heard_through_wall: int = _lone(&"hollow", 0, Vector3(150.0, 0.0, 0.0), 0.0)
	_idle_player(VARDHEIM, Vector3(-150.0, 0.0, -10.0))     # ahead, at 10 m
	_idle_player(SOLMARCH, Vector3(-90.0, 0.0, -20.0))      # ahead, but at 20 m (radius 16)
	_idle_player(VARDHEIM, Vector3(-30.0, 0.0, 8.0))        # behind, at 8 m (outside the 4 m hearing)
	_idle_player(SOLMARCH, Vector3(30.0, 0.0, -10.0))       # ahead, at 10 m, with a wall in between
	_idle_player(VARDHEIM, Vector3(90.0, 0.0, 3.0))         # behind, at 3 m: within hearing
	_idle_player(SOLMARCH, Vector3(150.0, 0.0, 4.0))        # behind, at 4 m, with a wall in between
	await _rig.advance(120)
	assert_ne_int(_brain(in_front).state, STATE_REST, "the one in front sees it")
	assert_eq(_brain(too_far).state, STATE_REST, "at 20 m it is outside the sight radius")
	assert_eq(_brain(behind).state, STATE_REST, "at its back and at 8 m it does not see it")
	assert_eq(_brain(behind_wall).state, STATE_REST, "with a wall in front it does not see it")
	assert_ne_int(_brain(heard).state, STATE_REST, "at its back but at 3 m it notices")
	assert_eq(_brain(heard_through_wall).state, STATE_REST, "hearing does not go through a wall either")


func assert_ne_int(actual: int, unexpected: int, message: String = "") -> bool:
	return assert_true(actual != unexpected, "%s (was %d)" % [message, actual])


func test_a_safe_player_in_their_own_camp_is_not_a_target_and_a_protected_one_neither() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"vardheim", Vector3(0.0, 0.0, -10.0), 8.0))
	var hollow: int = _lone(&"hollow", 0, Vector3(0.0, 0.0, 0.0), 0.0)
	var safe: int = _idle_player(VARDHEIM, Vector3(0.0, 0.0, -9.0))
	await _rig.advance(90)
	assert_eq(_brain(hollow).state, STATE_REST, "it does not chase someone it cannot touch: they are safe in their safe zone")
	# Outside the safe zone it does.
	_rig.server.teleport(safe, Vector3(0.0, 0.0, -0.5))
	await _rig.advance(30)
	assert_ne_int(_brain(hollow).state, STATE_REST, "outside the safe zone, they are a target now")


# --- Determinism ------------------------------------------------------------------------------

## A Hollow with seed [param hollow_seed] against a combat bot with seed [param bot_seed]
## for [param ticks] ticks. Returns the state sequence and the final state (positions and health).
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
	assert_true((first["log"] as Array).size() >= 3, "the fight goes through several states (%s)" % [first["log"]])
	assert_eq(first["log"], second["log"], "the same state sequence, with the same ticks")
	assert_eq(first["hollow_position"], second["hollow_position"], "and the same final position")
	assert_eq(first["bot_position"], second["bot_position"])
	assert_eq(first["hollow_health"], second["hollow_health"], "and the same health values")
	assert_eq(first["bot_health"], second["bot_health"])
	# With another NPC seed its reactions change: the sequence with its ticks is not the same.
	var other: Dictionary = await _duel(8, 3, 1500)
	assert_true(other["log"] != first["log"] or other["hollow_health"] != first["hollow_health"],
			"another seed, another fight")


# --- Step 0 of the tick -----------------------------------------------------------------------

func test_brains_think_before_anyone_is_simulated_in_the_tick() -> void:
	await _flat_with_no_spawners()
	var seen: Dictionary = {"checks": 0, "bad": 0}
	var rig: NpcRig = _rig
	# A spy NPC, with the highest id: it looks at all bodies at the start of its turn on every tick.
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
	assert_true(spy > other, "the spy has the highest id")
	await _rig.advance(60)
	assert_true(seen["checks"] > 100, "the spy has looked at everyone (%d)" % seen["checks"])
	assert_eq(seen["bad"], 0, "no body was already simulated in the tick: the brains see the state after s - 1")


func test_a_brain_thinks_every_six_ticks_and_repeats_its_plan_in_between() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	await _rig.advance(120)
	assert_true(brain.get_think_count() >= 19 and brain.get_think_count() <= 22,
			"about 20 thoughts in 120 ticks (%d)" % brain.get_think_count())
	assert_eq(HfsmBrain.THINK_INTERVAL_TICKS, 6)


# --- Tokens ------------------------------------------------------------------------------------

## Four Solmarch guards surround a Vardheim player who is healed on every tick. Returns what is measured.
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
	assert_true(stats["max"] <= 2, "never more than 2 attack at once (maximum seen: %d)" % stats["max"])
	assert_true(stats["max"] >= 2, "but two do get to attack at once: the test measures something")
	assert_true(stats["two"] > 100, "and they do so often (%d ticks with two)" % stats["two"])
	assert_true(stats["damage"] > 300, "the player takes damage (%d)" % stats["damage"])
	assert_true(stats["denied"] > 10, "the tokens are denied to the others (%d)" % stats["denied"])


func test_the_ones_without_a_token_circle_the_player_at_three_to_four_meters() -> void:
	var stats: Dictionary = await _four_guards_against_one(1800)
	var ring: Array = stats["ring"]
	assert_true(ring.size() > 200, "there are many samples of NPCs waiting for their turn (%d)" % ring.size())
	var sum: float = 0.0
	var inside: int = 0
	for distance: float in ring:
		sum += distance
		if distance >= 2.5 and distance <= 4.8:
			inside += 1
	assert_near(sum / float(ring.size()), 3.5, 0.6, "at about 3.5 m on average")
	assert_true(float(inside) / float(ring.size()) > 0.6, "and most of the time within 2.5 to 4.8 m")


func test_attack_tokens_are_released_when_the_npc_dies_or_loses_the_target() -> void:
	var tokens := AttackTokens.new()
	assert_true(tokens.try_claim(9, 1, 100))
	assert_true(tokens.try_claim(9, 2, 100))
	assert_false(tokens.try_claim(9, 3, 100), "the third token is denied")
	assert_true(tokens.try_claim(9, 1, 110), "whoever already has it keeps it")
	assert_eq(tokens.count(9, 110), 2)
	tokens.release_all(1)
	assert_true(tokens.try_claim(9, 3, 111), "on release one is left free")
	assert_false(tokens.try_claim(9, 4, 111))
	# A token expires on its own.
	assert_true(tokens.try_claim(9, 4, 111 + AttackTokens.TTL_TICKS + 1), "once expired, they are handed out again")
	assert_false(tokens.renew(9, 2, 111 + AttackTokens.TTL_TICKS + 1), "an expired one is not renewed")
	assert_true(tokens.try_claim(10, 1, 111), "against another target it is another count")


# --- Leash -------------------------------------------------------------------------------------

func test_the_leash_sends_the_npc_back_regenerated_and_immune() -> void:
	await _flat_with_no_spawners()
	var post := Vector3(0.0, 0.0, 0.0)
	var hollow: int = _lone(&"hollow", 0, post, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	var combatant: Combatant = _rig.combatant(hollow)
	# A player fleeing west at sprint speed (a bit more than the Hollow, which goes at 85%).
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
	assert_eq(brain.state, STATE_COMBAT, "it has hooked onto the player")
	combatant.health = roundi(float(combatant.max_health) * 0.25)
	var leash: float = NpcCatalog.get_definition(&"hollow").leash_radius
	var farthest: Dictionary = {"distance": 0.0}
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		farthest["distance"] = maxf(farthest["distance"],
				_rig.entity(hollow).get_position().distance_to(post)))
	running["run"] = true
	var returned: bool = await _rig.advance_until(func() -> bool: return brain.state == STATE_RETURN, 1200)
	if not assert_true(returned, "past the leash, it returns (state %s)" % HfsmBrain.state_name(brain.state)):
		return
	var now: int = _rig.server.get_tick()
	assert_true(combatant.is_protected(now), "the return is immune")
	assert_true((combatant.status_bits(now) & NetMessages.STATUS_PROTECTED) != 0, "and the clients see it protected")
	assert_true(combatant.health < combatant.max_health, "it is not yet regenerated halfway")
	assert_true(farthest["distance"] <= leash + 4.0, "it did not go much further than its leash (%.1f m of %.1f)"
			% [farthest["distance"], leash])
	assert_true(farthest["distance"] >= leash - 1.0, "and it did reach it (%.1f m)" % farthest["distance"])
	var home: bool = await _rig.advance_until(func() -> bool: return brain.state != STATE_RETURN, 2400)
	assert_true(home, "it reaches its post")
	assert_eq(brain.state, STATE_REST, "and stays at rest")
	assert_eq(combatant.health, combatant.max_health, "fully regenerated")
	assert_false(combatant.is_protected(_rig.server.get_tick()), "and no longer immune")
	assert_true(_rig.entity(hollow).get_position().distance_to(post) < 2.5, "at its post")
	assert_true(player > 0)


# --- Attacked from afar (phase 4 review, "traps" lens) --------------------------------------------

## [param count] Vardheim archers with the bow at z = [param z] (3 m apart) that fire the light attack at
## [param target_id] (with drop compensated) two ticks out of every 40, staggered. Returns their net_ids.
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
		assert_true(_rig.server.get_combat().set_weapon(_rig.combatant(net_id), bow), "with the bow")
		archers.append(net_id)
	return archers


func _damage_taken(net_ids: Array[int]) -> int:
	var total: int = 0
	for net_id: int in net_ids:
		total += _rig.combatant(net_id).max_health - _rig.combatant(net_id).health
	return total


## Before, an NPC hit from beyond its loss radius (28 m for the Hollow; the arrow reaches about 90 m) entered
## combat without a target, stood still and after 3 s went back to its post fully healed, and started over: with
## few archers it could not be killed and with many it died without moving or doing damage. Now it goes after whoever shoots it.
func test_an_npc_shot_from_beyond_its_lose_radius_goes_for_the_archers() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	var lose: float = NpcCatalog.get_definition(&"hollow").lose_radius
	assert_true(33.0 > lose, "the archers, beyond its loss radius (%.0f m)" % lose)
	var archers: Array[int] = _archers(3, -33.0, hollow)
	var hit: bool = await _rig.advance_until(func() -> bool:
		return _rig.combatant(hollow).health < _rig.combatant(hollow).max_health, 300)
	if not assert_true(hit, "the arrows hit it"):
		return
	var rests_before: int = _states(hollow).count(STATE_REST)
	var fought_back: bool = await _rig.advance_until(func() -> bool: return _damage_taken(archers) > 0, 1200)
	var position: Vector3 = _rig.entity(hollow).get_position()
	assert_true(fought_back, "it reaches the archers and damages them (it is at %s, %s)"
			% [position, HfsmBrain.state_name(brain.state)])
	assert_true(position.z < -25.0, "it has gone after them (z = %.1f)" % position.z)
	assert_eq(_states(hollow).count(STATE_REST), rests_before, "without returning to its post healed in between")
	assert_eq(_states(hollow).count(STATE_RETURN), 0, "nor returning: the archers are within its leash")


## If whoever shoots it is beyond its leash, it chases them up to it and returns immune (it does not stand still
## taking arrows).
func test_an_npc_shot_from_beyond_its_leash_chases_to_the_leash_and_returns_immune() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	var brain: HfsmBrain = _brain(hollow)
	var leash: float = NpcCatalog.get_definition(&"hollow").leash_radius
	var archers: Array[int] = _archers(3, -55.0, hollow)
	var returned: bool = await _rig.advance_until(func() -> bool: return brain.state == STATE_RETURN, 1500)
	if not assert_true(returned, "past the leash, it returns (state %s, at %s)"
			% [HfsmBrain.state_name(brain.state), _rig.entity(hollow).get_position()]):
		return
	assert_true(_rig.entity(hollow).get_position().length() >= leash - 1.0, "after chasing them to its leash")
	assert_true(_rig.combatant(hollow).is_protected(_rig.server.get_tick()), "immune while returning")
	assert_eq(_damage_taken(archers), 0, "without reaching them")
	assert_true(_rig.combatant(hollow).is_alive())


## Phase 4 review (traps): an NPC's state log is bounded (before, it grew without limit: a patrolling Hollow
## adds about 10 transitions per minute for days).
func test_the_state_log_keeps_only_the_latest_transitions() -> void:
	var brain := HfsmBrain.new(1)
	var transitions: int = HfsmBrain.STATE_LOG_MAX * 10
	for index: int in transitions:
		brain._enter(STATE_REST if index % 2 == 0 else HfsmBrain.State.PATROL, index)
	var entries: Array[Vector2i] = brain.get_state_log()
	assert_true(entries.size() >= HfsmBrain.STATE_LOG_MAX and entries.size() < HfsmBrain.STATE_LOG_MAX * 2,
			"between the cap and double (%d)" % entries.size())
	assert_eq(entries[entries.size() - 1], Vector2i(transitions - 1, HfsmBrain.State.PATROL), "with the last one")
	var contiguous: bool = true
	for index: int in range(1, entries.size()):
		contiguous = contiguous and entries[index].x == entries[index - 1].x + 1
	assert_true(contiguous, "and the previous ones consecutive, without gaps")


# --- Group alert and shout -------------------------------------------------------------------

func test_a_group_alert_wakes_the_nearby_members_and_not_the_far_ones() -> void:
	await _flat_with_no_spawners()
	var group: StringName = &"banda"
	var seen: int = _lone(&"hollow", 0, Vector3(0.0, 0.0, 0.0), 0.0, group)
	var near: int = _lone(&"hollow", 0, Vector3(20.0, 0.0, 0.0), PI, group)     # at 20 m, back turned
	var far: int = _lone(&"hollow", 0, Vector3(60.0, 0.0, 0.0), PI, group)      # a 60 m
	var other_group: int = _lone(&"hollow", 0, Vector3(10.0, 0.0, 12.0), PI, &"otra")
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	await _rig.advance(90)
	assert_eq(_brain(seen).state, STATE_COMBAT, "the one that sees it")
	assert_true(_brain(near).state == STATE_ALERT or _brain(near).state == STATE_COMBAT,
			"the group member at 20 m finds out even without seeing it")
	assert_eq(_brain(far).state, STATE_REST, "at 60 m the 25 m alert does not reach")
	assert_eq(_brain(other_group).state, STATE_REST, "nor another group")


func test_the_captains_shout_reaches_the_hollows_of_the_fort_but_only_if_there_are_any() -> void:
	await _flat_with_no_spawners()
	var group: StringName = &"vado"
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0, group)
	var hollow: int = _lone(&"hollow", 0, Vector3(50.0, 0.0, 0.0), PI, group)   # at 50 m, back turned
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	await _rig.advance(120)
	assert_eq(_brain(captain).state, STATE_COMBAT)
	assert_true(_brain(hollow).state == STATE_ALERT or _brain(hollow).state == STATE_COMBAT,
			"the shout reaches 50 m, beyond the 25 m of the normal alert")


func test_the_captain_calls_two_hollows_at_half_health_only_if_hollows_remain() -> void:
	await _flat_with_no_spawners()
	var group: StringName = &"vado"
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0, group)
	var hollow: int = _lone(&"hollow", 0, Vector3(15.0, 0.0, 0.0), PI, group)
	var player: int = _idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	var captain_combatant: Combatant = _rig.combatant(captain)
	var hollows_before: int = _count_npcs_of(&"hollow")
	await _rig.advance(60)
	assert_eq(_count_npcs_of(&"hollow"), hollows_before, "with full health there are no reinforcements")
	captain_combatant.health = roundi(float(captain_combatant.max_health) * 0.5) - 10
	await _rig.advance(40)
	assert_eq(_count_npcs_of(&"hollow"), hollows_before + 2, "at 50 %% health two more Hollows arrive")
	await _rig.advance(40)
	assert_eq(_count_npcs_of(&"hollow"), hollows_before + 2, "and only once")
	var reinforcement: NetEntity = null
	for entity: NetEntity in _rig.server.get_registry().get_sorted():
		if entity.kind == NetProtocol.EntityKind.NPC and entity.net_id > hollow and entity.net_id != captain \
				and entity.npc_def_id == NpcCatalog.number_of(&"hollow"):
			reinforcement = entity
	assert_not_null(reinforcement, "there are reinforcements")
	assert_true(reinforcement.get_position().distance_to(_rig.entity(captain).get_position()) < 8.0,
			"they appear next to the Captain")
	assert_true(_loose_brain(reinforcement.net_id) != null)
	assert_true(_loose_brain(reinforcement.net_id).state != STATE_REST, "and are already alert")
	assert_true(player > 0)


func test_the_captain_does_not_call_reinforcements_when_no_hollow_is_left() -> void:
	await _flat_with_no_spawners()
	var captain: int = _lone(&"ford_captain", 0, Vector3(0.0, 0.0, 0.0), 0.0, &"vado")
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -8.0))
	var combatant: Combatant = _rig.combatant(captain)
	combatant.health = roundi(float(combatant.max_health) * 0.5) - 10
	await _rig.advance(120)
	assert_eq(_count_npcs_of(&"hollow"), 0, "without living Hollows there are no reinforcements")


func _count_npcs_of(definition_id: StringName) -> int:
	var total: int = 0
	var number: int = NpcCatalog.number_of(definition_id)
	for entity: NetEntity in _rig.server.get_registry().get_sorted():
		if entity.kind == NetProtocol.EntityKind.NPC and entity.npc_def_id == number \
				and _rig.combatant(entity.net_id).is_alive():
			total += 1
	return total


# --- Unblockable and telegraphed hit ------------------------------------------------------------

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
	assert_true(found, "the Captain ends up throwing his heavy attack")
	var telegraphs: Array[NetMessages.EntityEvent] = _rig.events_of(NetMessages.EntityEvent.Kind.TELEGRAPH)
	if not assert_false(telegraphs.is_empty(), "the heavy attack is announced with a TELEGRAPH"):
		return
	var crush: AttackTicks = CombatCatalog.attack(crush_id)
	var telegraph: NetMessages.EntityEvent = telegraphs[0]
	assert_eq(telegraph.net_id, captain, "from the Captain")
	assert_eq(telegraph.attack_id, crush_id)
	assert_eq(telegraph.shape, NetMessages.EntityEvent.SHAPE_SECTOR, "a sector")
	assert_eq(telegraph.radius_cm, roundi(crush.shape.range_m * 100.0), "with the attack's reach")
	assert_eq(telegraph.impact_in_ticks, crush.windup_ticks, "it warns for the whole windup")
	assert_true(telegraph.impact_in_ticks >= 42, "and is legible: at least 0.7 s")
	# The hit reaches whoever blocks, with full damage and without the block mark.
	var crush_hit: NetMessages.EntityEvent = null
	var sweep_hits: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _rig.events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id != blocker:
			continue
		if event.attack_id == crush_id and crush_hit == null:
			crush_hit = event
		elif event.attack_id == sweep_id:
			sweep_hits.append(event)
	if assert_not_null(crush_hit, "the unblockable hit lands"):
		assert_false(crush_hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "without blocking")
		assert_false(crush_hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), "nor parrying")
		assert_eq(crush_hit.amount, crush.base_damage, "with all its damage")
		assert_true(crush_hit.tick - telegraph.tick >= crush.windup_ticks, "not before the windup ends")
	assert_true(sweep_hits.size() >= 1, "before that there were sweeps")
	for sweep: NetMessages.EntityEvent in sweep_hits:
		assert_true(sweep.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "and the shield stopped them")


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


## An NPC of [param definition_id] that only attacks with the heavy attack against a player who blocks it 550 ms
## after seeing it begin: all heavy attacks (of [param attack_name]) must arrive blocked.
func _check_every_heavy_is_blocked(definition_id: StringName, realm: int, attack_name: StringName) -> void:
	var definition: NpcDefinition = NpcCatalog.get_definition(definition_id).duplicate() as NpcDefinition
	definition.heavy_chance = 1.0
	definition.block_chance = 0.0
	var brain := HfsmBrain.new(5)
	var npc: int = _rig.server.add_npc(brain, "PNJ", realm, Vector3.ZERO, 0.0, false, definition)
	brain.bind(_rig.npcs().get_world(), _rig.entity(npc), _rig.combatant(npc), definition, Vector3.ZERO, 0.0)
	# With an RTT of 200 ms (--net-sim=rtt=200) the player sees the windup 100 ms later (half the RTT) plus about
	# 100 ms of interpolation delay, reacts 250 ms later and their input takes another 100 ms to reach the
	# server: 550 ms, 33 ticks.
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
	assert_true(heavies >= 4, "%s throws several heavy attacks (%d)" % [definition_id, heavies])
	assert_eq(blocked, heavies, "and the player, with a 550 ms delay, blocks them all")
	assert_true(CombatCatalog.attack(heavy_id).windup_ticks > delay + 6, "the windup (%d ticks) leaves room for that reaction"
			% CombatCatalog.attack(heavy_id).windup_ticks)


# --- Debugging --------------------------------------------------------------------------------

func test_npc_debug_writes_state_target_and_path_every_second() -> void:
	await _flat_with_no_spawners()
	var hollow: int = _lone(&"hollow", 0, Vector3.ZERO, 0.0)
	_idle_player(VARDHEIM, Vector3(0.0, 0.0, -9.0))
	var lines: PackedStringArray = PackedStringArray()
	_rig.npcs().log_sink = func(line: String) -> void: lines.append(line)
	# Off by default: no lines.
	await _rig.advance(130)
	assert_true(lines.is_empty(), "without the command nothing is written")
	assert_false(_rig.npcs().is_debug_enabled())
	assert_eq(_rig.server.console_command("npc_debug on"), "Depuración de PNJ activada")
	assert_true(_rig.npcs().is_debug_enabled())
	await _rig.advance(125)
	assert_true(lines.size() >= 2, "one line per NPC per second (%d)" % lines.size())
	assert_true(lines[0].contains("Hueco") and lines[0].contains("estado=") and lines[0].contains("objetivo=")
			and lines[0].contains("ruta=") and lines[0].contains("vida="), lines[0])
	assert_true(lines[lines.size() - 1].contains("estado=combate"), "it states the state: %s" % lines[lines.size() - 1])
	# Over the network (id 12), with the DebugCommand data.
	var peer := ServerPeer.new(3)
	assert_eq(_rig.server.get_commands().execute_network(peer, NetProtocol.DEBUG_NPC_DEBUG, PackedByteArray([0])),
			CommandRegistry.Result.OK, "turning off over the network")
	assert_false(_rig.npcs().is_debug_enabled())
	assert_eq(_rig.server.get_commands().execute_network(peer, NetProtocol.DEBUG_NPC_DEBUG, PackedByteArray([2])),
			CommandRegistry.Result.BAD_ARGUMENTS, "a value that is neither 0 nor 1 is not valid")
	assert_eq(_rig.server.get_commands().execute_network(peer, NetProtocol.DEBUG_NPC_DEBUG, PackedByteArray([1])),
			CommandRegistry.Result.OK, "turning on over the network")
	assert_true(_rig.npcs().is_debug_enabled())
	assert_true(hollow > 0)
	# Those of protocol 6: 13 and 14 arrived with H3a; 15 and 16, with H3c (docs/habilidades.md §7.1). The four for
	# progression in protocol 7 (40 to 43), with progresion.md P5d.
	assert_eq(_rig.server.get_commands().missing_network_commands(), PackedStringArray(),
			"with npc_debug all the network commands are there")
