extends TestCase
## Tests for the knocked-down state (CMB-28; docs/abilities.md, section 4.5; package H3c) inside the [ZoneServer]: the
## killing blow between players of two realms knocks down, the three outcomes (revived in 180 ticks with 300
## health, finished off in 60 with the finishing blow source and KILL, bled out in 1200 with the killer who knocked down), revive
## cut off by damage to the reviver and to the knocked-down player, no finishing through the closed gate (and broken, yes), the
## gate is not repaired with a knocked-down player in the doorway, the removal of a knocked-down player is first their death (CLIENT_LEAVE with
## ENet, the fake that leaves and the body of GUE-41) and on returning they appear in the camp, direct death against
## an NPC, the NPC that prefers the knocked-down player and finishes them with damage, command 15 without KILL and the discarding of
## hits from the same tick. H5 revision: starting to finish off removes respawn protection (so the
## knocked-down player's allies can cut it off), and the finishing is cut off if the knocked-down player crawls into their camp.
## [br][br]
## Almost all with scripted fake players on the flat zone of [ZoneFixture] ([NpcRig] setup), advanced
## quickly with their [FortressFixture.Stepper]; the exit, with real clients over ENet on 127.0.0.1.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const DEATH: int = NetMessages.EntityEvent.Kind.DEATH
const KILL: int = NetMessages.EntityEvent.Kind.KILL
const DOWNED: int = NetMessages.EntityEvent.Kind.DOWNED
const INTERACT: int = NetMessages.EntityEvent.Kind.INTERACT
const OP_REVIVE: int = NetMessages.EntityEvent.InteractOp.REVIVE
const OP_REVIVE_CUT: int = NetMessages.EntityEvent.InteractOp.REVIVE_CUT
const OP_REVIVED: int = NetMessages.EntityEvent.InteractOp.REVIVED
const OP_EXECUTE: int = NetMessages.EntityEvent.InteractOp.EXECUTE
const OP_EXECUTE_CUT: int = NetMessages.EntityEvent.InteractOp.EXECUTE_CUT
const WAIT_FRAMES: int = 900

var _rig: NpcRig = null
# The ENet test stuff.
var _server_viewport: SubViewport = null
var _client_viewports: Array[SubViewport] = []
var _net_server: ZoneServer = null


## What a fake player does each tick: looks at [member look_yaw], moves with [member move] in
## [code][move_from, move_to)[/code] and holds each button of [member holds] in its interval.
class Plan:
	extends RefCounted

	var look_yaw: float = 0.0
	var move: Vector2 = Vector2.ZERO
	var move_from: int = -1
	var move_to: int = -1
	## (button, from, to) with an exclusive end.
	var holds: Array[Vector3i] = []


	func hold(button: int, from_tick: int, to_tick: int) -> void:
		holds.append(Vector3i(button, from_tick, to_tick))


	func input_for(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = look_yaw
		if tick >= move_from and tick < move_to:
			input.move = move
		for entry: Vector3i in holds:
			if tick >= entry.y and tick < entry.z:
				input.buttons |= entry.x
		return input


func before_each() -> void:
	_rig = NpcRig.new()


func after_each() -> void:
	if _rig != null:
		await _rig.stop()
	_rig = null
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.get_parent().remove_child(viewport)
			viewport.free()
	_client_viewports.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.get_parent().remove_child(_server_viewport)
		_server_viewport.free()
	_server_viewport = null
	_net_server = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _server() -> ZoneServer:
	return _rig.server


func _combatant(net_id: int) -> Combatant:
	return _server().get_combat().get_combatant(net_id)


func _combat_of(net_id: int) -> CombatState:
	return _rig.character(net_id).combat


## A fake player of [param realm] at [param position] facing [param yaw] that follows [param plan].
func _scripted(realm: int, position: Vector3, yaw: float, plan: Plan) -> int:
	plan.look_yaw = yaw
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return plan.input_for(tick)
	return _rig.add_player(realm, position, brain, yaw)


func _events_of(kind: int, net_id: int = -1) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _rig.events:
		if event.event == kind and (net_id < 0 or event.net_id == net_id):
			found.append(event)
	return found


func _light_id() -> int:
	return CombatCatalog.weapon(CombatCatalog.weapon_id(&"sword_shield")).light_ids[0]


## Advances to server tick [param tick] (if it has not passed already).
func _advance_to(tick: int) -> void:
	var remaining: int = tick - _server().get_tick()
	if remaining > 0:
		await _rig.advance(remaining)


## The Vardheim attacker at the origin facing -Z and the Solmarch victim 1.5 m in front, facing it, with 50
## health: the attacker's light attack knocks it down. Returns [code][attacker, victim, knock-down tick][/code] and the
## plans in [param plans] (the attacker's and the victim's).
func _downed_pair(plans: Array[Plan] = []) -> Array[int]:
	var attacker_plan := Plan.new()
	var victim_plan := Plan.new()
	plans.append(attacker_plan)
	plans.append(victim_plan)
	var attacker: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, attacker_plan)
	var victim: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), PI, victim_plan)
	_combatant(victim).health = 50
	var press: int = _server().get_tick() + 3
	attacker_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	var downed: bool = await _rig.advance_until(func() -> bool: return _combatant(victim).is_downed(), 120, 2)
	assert_true(downed, "the light attack knocks the victim down")
	var downs: Array[NetMessages.EntityEvent] = _events_of(DOWNED, victim)
	return [attacker, victim, downs[0].tick if not downs.is_empty() else -1]


# --- Falling ----------------------------------------------------------------------------------

func test_a_lethal_hit_between_two_realms_downs_the_player_instead_of_killing_it() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	var down_tick: int = ids[2]
	var combatant: Combatant = _combatant(victim)
	assert_true(combatant.is_downed())
	assert_false(combatant.is_alive(), "a knocked-down player is not alive")
	assert_false(combatant.is_dead(), "nor dead")
	assert_eq(combatant.health, 0)
	assert_eq(combatant.downed_by, attacker)
	assert_eq(combatant.downed_source, _light_id())
	assert_eq(_combat_of(victim).action, CombatState.Action.DOWNED)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
	if assert_eq(hits.size(), 1, "one HIT"):
		assert_eq(hits[0].hit_flags, NetMessages.EntityEvent.HIT_FLAG_DOWNED, "with bit 6 and without the lethal one")
		assert_eq(hits[0].tick, down_tick)
	var downs: Array[NetMessages.EntityEvent] = _events_of(DOWNED, victim)
	if assert_eq(downs.size(), 1, "one DOWNED"):
		assert_eq(downs[0].attacker, attacker)
		assert_eq(downs[0].get_source(), _light_id())
	assert_eq(_events_of(DEATH).size(), 0, "nobody dies")
	assert_eq(_events_of(KILL).size(), 0)
	# What the snapshots publish: the knocked-down health over 400 and bit 3, without the dead one.
	var entity: NetEntity = _rig.entity(victim)
	assert_eq(entity.max_health, 400)
	assert_true(entity.health > 390 and entity.health <= 400, "knocked-down health (%d)" % entity.health)
	assert_true(entity.health_q > 0, "the quantized health of a knocked-down player is never 0")
	assert_true((entity.status & NetMessages.STATUS_DOWNED) != 0)
	assert_eq(entity.status & NetMessages.STATUS_DEAD, 0)
	# It neither respawns nor heals nor receives effects.
	assert_eq(_server().get_combat().request_respawn(victim, 0, _server().get_tick() + 1),
			CombatDirector.RespawnRequestResult.NOT_DEAD)
	assert_eq(_server().console_command("heal %d" % victim), "%s está derribado" % entity.display_name)
	assert_false(_server().get_combat().apply_status(combatant, CombatCatalog.status_id(&"bleed"),
			_server().get_tick() + 1))
	# It crawls at ×0.15: 2 s walking forward is under 2 m (on foot it would be 10).
	var start: Vector3 = entity.get_position()
	plans[1].move = Vector2(0.0, 1.0)
	plans[1].move_from = _server().get_tick() + 1
	plans[1].move_to = _server().get_tick() + 121
	await _rig.advance(121)
	var crawled: float = Vector2(entity.get_position().x - start.x, entity.get_position().z - start.z).length()
	assert_true(crawled > 0.5 and crawled < 2.0, "crawls slowly (%.2f m in 2 s)" % crawled)
	var report: Dictionary = _server()._combat_report()
	assert_eq(int(report.get("downs", -1)), 1, "the report counts the knock-down")
	assert_eq(int(report.get("downed_now", -1)), 1)


# --- The three outcomes -----------------------------------------------------------------------

func test_an_ally_revives_in_180_ticks_with_300_health_and_back_to_none() -> void:
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var victim: int = ids[1]
	var ally_plan := Plan.new()
	var ally: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -3.0), PI, ally_plan)
	await _rig.advance(4)
	var start: int = _server().get_tick() + 2
	ally_plan.hold(PlayerInput.INTERACT, start, start + 240)
	await _advance_to(start + 90)
	assert_eq(_combat_of(ally).action, CombatState.Action.REVIVE, "halfway, reviving")
	assert_true(_combatant(victim).is_downed(), "and still knocked down")
	await _advance_to(start + 179)
	assert_true(_combatant(victim).is_downed(), "at tick 179 not yet")
	await _advance_to(start + 180)
	var revived: Combatant = _combatant(victim)
	assert_false(revived.is_downed(), "at 180, revived")
	assert_true(revived.is_alive())
	assert_eq(revived.health, 300, "with 300 health")
	assert_eq(_combat_of(victim).action, CombatState.Action.NONE, "and in NONE")
	assert_eq(_combat_of(ally).action, CombatState.Action.NONE, "the reviver returns to NONE")
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 2, "INTERACT 1 and 3"):
		assert_eq(interacts[0].op, OP_REVIVE)
		assert_eq(interacts[0].actor, ally)
		assert_eq(interacts[0].tick, start)
		assert_eq(interacts[0].end_tick, start + 180, "with the tick at which it will end")
		assert_eq(interacts[1].op, OP_REVIVED)
		assert_eq(interacts[1].tick, start + 180)
	assert_eq(_rig.entity(victim).status & NetMessages.STATUS_DOWNED, 0, "without the knocked-down bit")
	assert_eq(_rig.entity(victim).max_health, 1000)
	assert_eq(_events_of(DEATH).size(), 0)
	# Holding E without releasing does not start anything else: there are no knocked-down players left.
	await _rig.advance(30)
	assert_eq(_events_of(INTERACT, victim).size(), 2)
	assert_eq(int(_server()._combat_report().get("revives", -1)), 1)


func test_an_enemy_executes_in_60_ticks_with_the_execute_source_and_a_kill() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	# When the light attack has ended, the attacker holds E.
	var start: int = ids[2] + 60
	plans[0].hold(PlayerInput.INTERACT, start, start + 90)
	await _advance_to(start + 30)
	assert_eq(_combat_of(attacker).action, CombatState.Action.EXECUTE, "finishing off")
	await _advance_to(start + 59)
	assert_true(_combatant(victim).is_downed())
	await _advance_to(start + 60)
	assert_true(_combatant(victim).is_dead(), "finished off in 60 ticks")
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 1, "INTERACT 4"):
		assert_eq(interacts[0].op, OP_EXECUTE)
		assert_eq(interacts[0].actor, attacker)
		assert_eq(interacts[0].end_tick, start + 60)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1, "one DEATH"):
		assert_eq(deaths[0].tick, start + 60)
		assert_eq(deaths[0].killer, attacker)
		assert_eq(deaths[0].get_source(), CombatSource.EXECUTE, "with the finishing blow source")
	var kills: Array[NetMessages.EntityEvent] = _events_of(KILL, victim)
	if assert_eq(kills.size(), 1, "and its KILL"):
		assert_eq(kills[0].killer, attacker)
		assert_eq(kills[0].get_source(), CombatSource.EXECUTE)
	assert_eq(_server().get_scores().get_entry(attacker).kills, 1, "the kill counts on the scoreboard")
	assert_eq(_combat_of(attacker).action, CombatState.Action.NONE)
	assert_eq(int(_server()._combat_report().get("executions", -1)), 1)


func test_a_downed_bleeds_out_in_1200_ticks_and_the_one_who_downed_it_gets_the_kill() -> void:
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var attacker: int = ids[0]
	var victim: int = ids[1]
	var down_tick: int = ids[2]
	await _advance_to(down_tick + 600)
	assert_eq(_combatant(victim).downed_health, 200, "−1 every 3 ticks: 200 at 600")
	assert_eq(_rig.entity(victim).health, 200, "and that is what it publishes")
	await _advance_to(down_tick + 1199)
	assert_eq(_combatant(victim).downed_health, 1)
	assert_eq(_events_of(DEATH).size(), 0)
	await _advance_to(down_tick + 1200)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1, "bled out at 1200 ticks"):
		assert_eq(deaths[0].tick, down_tick + 1200)
		assert_eq(deaths[0].killer, attacker, "the killer is whoever knocked them down")
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT, "with the bleed-out source")
	var kills: Array[NetMessages.EntityEvent] = _events_of(KILL, victim)
	if assert_eq(kills.size(), 1):
		assert_eq(kills[0].killer, attacker)
	assert_true(_combatant(victim).is_dead())
	assert_eq(_rig.entity(victim).status & NetMessages.STATUS_DEAD, NetMessages.STATUS_DEAD)
	assert_eq(int(_server()._combat_report().get("bled_out", -1)), 1)


# --- Cuts and line of sight -------------------------------------------------------------------

func test_damage_cuts_the_revive_on_whoever_revives_and_on_the_downed() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	# Let the light attack that knocked down finish (its active hit would reach whoever arrives).
	await _rig.advance(40)
	# The reviver, 1.8 m to the right of the knocked-down player facing -X; an enemy behind them, also facing -X,
	# 2.4 m from them and 4.2 from the knocked-down player (out of reach of their light attack, with its advance).
	var ally_plan := Plan.new()
	var ally: int = _scripted(SOLMARCH, Vector3(1.8, 0.05, -1.5), PI * 0.5, ally_plan)
	var enemy_plan := Plan.new()
	_scripted(VARDHEIM, Vector3(4.2, 0.05, -1.5), PI * 0.5, enemy_plan)
	await _rig.advance(4)
	var start: int = _server().get_tick() + 2
	ally_plan.hold(PlayerInput.INTERACT, start, start + 400)
	enemy_plan.hold(PlayerInput.PRIMARY, start + 20, start + 22)
	var cut: bool = await _rig.advance_until(func() -> bool:
		return _events_of(INTERACT, victim).size() >= 2, 120, 2)
	assert_true(cut, "the hit on the reviver cuts it off")
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if interacts.size() >= 2:
		assert_eq(interacts[0].op, OP_REVIVE)
		assert_eq(interacts[1].op, OP_REVIVE_CUT, "INTERACT 2")
		var ally_hits: Array[NetMessages.EntityEvent] = _events_of(HIT, ally)
		if assert_eq(ally_hits.size(), 1):
			assert_true((ally_hits[0].hit_flags & NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED) != 0,
					"the HIT carries bit 5")
			assert_eq(interacts[1].tick, ally_hits[0].tick, "on the tick of the hit")
	assert_eq(_combat_of(ally).action, CombatState.Action.NONE)
	assert_true(_combatant(victim).is_downed(), "the knocked-down player keeps waiting")
	# Again, from behind the knocked-down player (1.9 m from them) and with the attacker 0.6 m further back: its light attack, with its
	# advance, reaches the knocked-down player and not the reviver.
	_server().teleport(attacker, Vector3(0.0, 0.05, 0.6))
	_rig.character(attacker).yaw = 0.0
	_server().teleport(ally, Vector3(0.0, 0.05, -3.4))
	ally_plan.look_yaw = PI
	_rig.character(ally).yaw = PI
	ally_plan.holds.clear()
	var again: int = _server().get_tick() + 4
	ally_plan.hold(PlayerInput.INTERACT, again, again + 400)
	plans[0].hold(PlayerInput.PRIMARY, again + 20, again + 22)
	var cut_again: bool = await _rig.advance_until(func() -> bool:
		return _events_of(INTERACT, victim).size() >= 4, 120, 2)
	assert_true(cut_again, "the hit on the knocked-down player also cuts it off")
	interacts = _events_of(INTERACT, victim)
	if interacts.size() >= 4:
		assert_eq(interacts[2].op, OP_REVIVE)
		assert_eq(interacts[3].op, OP_REVIVE_CUT)
		var downed_hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
		if assert_eq(downed_hits.size(), 2, "the hit that knocked down and this one"):
			assert_eq(downed_hits[1].attacker, attacker)
			assert_eq(interacts[3].tick, downed_hits[1].tick)
			assert_true(_combatant(victim).downed_health < 400 - downed_hits[1].amount + 1,
					"the damage takes off knocked-down health")
	assert_eq(_combat_of(ally).action, CombatState.Action.NONE, "the one who was reviving returns to NONE")
	assert_eq(_events_of(HIT, ally).size(), 1, "without being hit themselves")


func test_no_execution_through_the_closed_gate_and_through_the_broken_one_yes() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		FortressFixture.add_fortress(world, FortressFixture.make_definition()))
	var gate_x: float = FortressFixture.gate_position().x
	# The knocked-down player inside, 1 m from the gate; the enemy outside, 0.8 m: 1.8 m between the two.
	var victim: int = _scripted(SOLMARCH, Vector3(gate_x + 1.0, 0.05, 0.0), PI * 0.5, Plan.new())
	var executor_plan := Plan.new()
	var executor: int = _scripted(VARDHEIM, Vector3(gate_x - 0.8, 0.05, 0.0), -PI * 0.5, executor_plan)
	await _rig.advance(3)
	assert_true(_server().get_combat().down(_combatant(victim), _server().get_tick() + 1))
	await _rig.advance(3)
	assert_true(_combatant(victim).is_downed())
	var start: int = _server().get_tick() + 2
	executor_plan.hold(PlayerInput.INTERACT, start, start + 20)
	await _advance_to(start + 30)
	assert_eq(_events_of(INTERACT, victim).size(), 0, "the closed gate cuts the line of sight")
	assert_eq(_combat_of(executor).action, CombatState.Action.NONE)
	# Broken, the same press finishes them off.
	var target: StructureTarget = _server().get_fortresses().get_structure_targets()[0]
	_server().get_fortresses().on_structure_hit(target, _combatant(executor), 900, _server().get_tick() + 1)
	await _rig.advance(3)
	assert_true(_server().get_fortresses().get_gate(FortressFixture.FORTRESS_ID).is_broken())
	var again: int = _server().get_tick() + 2
	executor_plan.hold(PlayerInput.INTERACT, again, again + 90)
	await _advance_to(again + 60)
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 1, "with the gate broken, INTERACT 4"):
		assert_eq(interacts[0].op, OP_EXECUTE)
	assert_true(_combatant(victim).is_dead(), "and finishes them off")


func test_an_executor_under_respawn_protection_loses_it_and_the_downeds_ally_cuts_it() -> void:
	await _rig.start_flat(tree)
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	await _rig.advance(60)
	# An ally of the knocked-down player 1.5 m from the finisher, facing them.
	var ally_plan := Plan.new()
	var ally: int = _scripted(SOLMARCH, Vector3(1.5, 0.05, 0.0), PI * 0.5, ally_plan)
	await _rig.advance(4)
	var start: int = _server().get_tick() + 2
	# As if the finisher had just respawned: protected 3 s.
	_combatant(attacker).protected_until = start + 180
	plans[0].hold(PlayerInput.INTERACT, start, start + 90)
	ally_plan.hold(PlayerInput.PRIMARY, start + 5, start + 7)
	await _advance_to(start + 61)
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 2, "INTERACT 4 and 5 (before: the finishing could not be cut off)"):
		assert_eq(interacts[0].op, OP_EXECUTE)
		assert_eq(_combatant(attacker).protected_until, interacts[0].tick,
				"starting to finish off removes the protection on that tick")
		assert_eq(interacts[1].op, OP_EXECUTE_CUT, "the ally's hit cuts it off")
		var attacker_hits: Array[NetMessages.EntityEvent] = _events_of(HIT, attacker)
		if assert_true(attacker_hits.size() >= 1, "the knocked-down player's ally hits them"):
			assert_eq(attacker_hits[0].attacker, ally)
			assert_true((attacker_hits[0].hit_flags & NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED) != 0,
					"with bit 5")
			assert_eq(interacts[1].tick, attacker_hits[0].tick, "on the tick of the hit")
	assert_true(_combatant(victim).is_downed(), "and the knocked-down player stays knocked down")
	assert_eq(_events_of(DEATH, victim).size(), 0)


func test_an_execution_is_cut_when_the_downed_crawls_into_its_camp() -> void:
	# A Solmarch camp of 10 m radius with its edge 0.25 m behind the knocked-down player (at z = -1.75).
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"solmarch", Vector3(0.0, 0.0, -1.75 - 10.0), 10.0))
	var plans: Array[Plan] = []
	var ids: Array[int] = await _downed_pair(plans)
	var attacker: int = ids[0]
	var victim: int = ids[1]
	await _rig.advance(60)
	var start: int = _server().get_tick() + 2
	plans[0].hold(PlayerInput.INTERACT, start, start + 90)
	# The knocked-down player crawls backwards (towards -Z), towards their camp.
	plans[1].move = Vector2(0.0, -1.0)
	plans[1].move_from = start + 1
	plans[1].move_to = start + 200
	var safe: SafeAreas = _server().get_combat().resolver.get_safe_areas()
	var inside_at: int = -1
	for rel: int in range(1, 70):
		await _advance_to(start + rel)
		if inside_at < 0 and safe.contains_own(SOLMARCH, _rig.entity(victim).get_position()):
			inside_at = _server().get_tick()
	assert_true(inside_at > start and inside_at < start + 60, "enters their camp before the end (%d)" % (
			inside_at - start))
	var interacts: Array[NetMessages.EntityEvent] = _events_of(INTERACT, victim)
	if assert_eq(interacts.size(), 2, "INTERACT 4 and 5 (before: finished off inside their camp)"):
		assert_eq(interacts[0].op, OP_EXECUTE)
		assert_eq(interacts[1].op, OP_EXECUTE_CUT, "inside their safe zone it is cut off")
		assert_eq(interacts[1].tick, inside_at, "on the tick they enter")
	assert_eq(_events_of(DEATH, victim).size(), 0, "no death from finishing off")
	assert_true(_combatant(victim).is_downed(), "still knocked down")
	assert_eq(_combat_of(attacker).action, CombatState.Action.NONE, "the one who was finishing off returns to NONE")


func test_the_gate_is_not_repaired_with_a_downed_player_in_the_doorway() -> void:
	var definition: FortressDefinition = FortressFixture.make_definition()
	definition.gate_repair_after_s = 5.0
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		FortressFixture.add_fortress(world, definition))
	var blocker: int = _scripted(VARDHEIM, FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0), 0.0,
			Plan.new())
	var target: StructureTarget = _server().get_fortresses().get_structure_targets()[0]
	_server().get_fortresses().on_structure_hit(target, _combatant(blocker), 900, _server().get_tick() + 1)
	await _rig.advance(3)
	assert_true(_server().get_combat().down(_combatant(blocker), _server().get_tick() + 1))
	await _rig.advance(6 * 60)
	assert_true(_combatant(blocker).is_downed())
	var gate: FortGate = _server().get_fortresses().get_gate(FortressFixture.FORTRESS_ID)
	assert_true(gate.is_broken(), "past the deadline, a knocked-down player in the doorway prevents the repair")
	assert_true(_server().get_fortresses().is_repair_pending(FortressFixture.FORTRESS_ID))
	assert_eq(_server().console_command("kill %d" % blocker), "%s muerto" % _rig.entity(blocker).display_name)
	await _rig.advance(3)
	assert_false(gate.is_broken(), "dead, the gate is repaired")


# --- Leaving while knocked down ---------------------------------------------------------------

func test_a_fake_that_leaves_while_downed_dies_first_with_death_and_kill() -> void:
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var attacker: int = ids[0]
	var victim: int = ids[1]
	assert_true(_server().remove_fake_player(victim))
	await _rig.advance(2)
	assert_null(_rig.server.get_registry().get_entity(victim), "se va")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1, "first, its DEATH"):
		assert_eq(deaths[0].killer, attacker, "at the hands of whoever knocked them down")
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT)
	assert_eq(_events_of(KILL, victim).size(), 1, "and its KILL")
	assert_eq(_server().get_scores().get_entry(attacker).kills, 1)


func test_a_filler_retired_while_downed_leaves_without_death_or_kill() -> void:
	# Skill integration review: the filler fake that gives up its place to a person (GUE-43) left like any
	# fake, and if it was knocked down its removal was a death with a KILL for whoever knocked it down: a
	# person joining added a death to a side. Removed with retire_filler, only the DESPAWN.
	await _rig.start_flat(tree)
	var ids: Array[int] = await _downed_pair()
	var attacker: int = ids[0]
	var victim: int = ids[1]
	assert_false(_server().is_fake_calm(victim), "the knocked-down one is not calm")
	assert_true(_server().is_fake_calm(attacker), "the one who knocked them down is")
	assert_true(_server().retire_filler(victim))
	await _rig.advance(2)
	assert_null(_rig.server.get_registry().get_entity(victim), "se va")
	assert_eq(_events_of(DEATH, victim).size(), 0, "no DEATH")
	assert_eq(_events_of(KILL, victim).size(), 0, "nor KILL")
	var entry: Variant = _server().get_scores().get_entry(attacker)
	assert_true(entry == null or entry.kills == 0, "nor death on the scoreboard")


func test_a_player_who_leaves_while_downed_dies_and_comes_back_at_the_camp() -> void:
	await _start_net_server()
	var events: Array[NetMessages.EntityEvent] = []
	_net_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: events.append(event))
	var client: NetClient = await _join_bot(SOLMARCH, 41)
	if not assert_not_null(client, "the bot enters"):
		return
	var net_id: int = client.get_net_id()
	var attacker: int = _net_server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combatant: Combatant = _net_server.get_combat().get_combatant(net_id)
	# Knocked down and in combat: even so its body does not stay (GUE-41), it dies.
	combatant.mark_combat(_net_server.get_tick() + 1)
	_net_server.get_combat().downed.down(combatant, attacker, _light_id(), _net_server.get_tick() + 1)
	await wait_physics_frames(3)
	assert_true(combatant.is_downed())
	client.leave()
	var gone: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _net_server.get_registry().get_entity(net_id) == null:
			gone = true
			break
	if not assert_true(gone, "leaves the zone"):
		return
	assert_false(_net_server.is_lingering(net_id), "no body stays behind")
	var deaths: Array[NetMessages.EntityEvent] = events.filter(func(event: NetMessages.EntityEvent) -> bool:
		return event.event == DEATH and event.net_id == net_id)
	if assert_eq(deaths.size(), 1, "dies on leaving"):
		assert_eq(deaths[0].killer, attacker)
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT)
	assert_eq(events.filter(func(event: NetMessages.EntityEvent) -> bool:
		return event.event == KILL and event.net_id == net_id).size(), 1, "with its KILL")
	# On returning they appear in their realm's camp, like anyone.
	var back: NetClient = await _join_bot(SOLMARCH, 41)
	if not assert_not_null(back, "enters again"):
		return
	var returned: Combatant = _net_server.get_combat().get_combatant(back.get_net_id())
	assert_true(returned.is_alive() and not returned.is_downed())
	assert_eq(returned.health, returned.max_health)
	var position: Vector3 = _net_server.get_registry().get_entity(back.get_net_id()).get_position()
	assert_true(Vector2(position.x - ZoneFixture.SOLMARCH_SPAWN.x, position.z - ZoneFixture.SOLMARCH_SPAWN.z).length()
			< 3.0, "at their realm's point (%s)" % position)


func test_a_lingering_body_downed_dies_when_its_time_runs_out() -> void:
	await _start_net_server()
	_net_server.linger_ticks = 90
	var events: Array[NetMessages.EntityEvent] = []
	_net_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: events.append(event))
	var client: NetClient = await _join_bot(SOLMARCH, 42)
	if not assert_not_null(client, "the bot enters"):
		return
	var net_id: int = client.get_net_id()
	var attacker: int = _net_server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	var combatant: Combatant = _net_server.get_combat().get_combatant(net_id)
	combatant.mark_combat(_net_server.get_tick() + 1)
	client.leave()
	var lingering: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _net_server.is_lingering(net_id):
			lingering = true
			break
	if not assert_true(lingering, "leaves in combat: its body stays"):
		return
	_net_server.get_combat().downed.down(combatant, attacker, _light_id(), _net_server.get_tick() + 1)
	var removed: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _net_server.get_registry().get_entity(net_id) == null:
			removed = true
			break
	assert_true(removed, "when its time ends it is removed")
	var deaths: Array[NetMessages.EntityEvent] = events.filter(func(event: NetMessages.EntityEvent) -> bool:
		return event.event == DEATH and event.net_id == net_id)
	if assert_eq(deaths.size(), 1, "and before that it dies"):
		assert_eq(deaths[0].killer, attacker)
		assert_eq(deaths[0].get_source(), CombatSource.BLEED_OUT)


# --- NPCs --------------------------------------------------------------------------------------

func test_a_lethal_hit_from_an_npc_kills_directly() -> void:
	await _rig.start_flat(tree)
	var npc_plan := Plan.new()
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return npc_plan.input_for(tick)
	var npc: int = _server().add_npc(brain, "Hueco", HUECOS, Vector3(0.0, 0.05, 0.0), 0.0)
	var victim: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), PI, Plan.new())
	_combatant(victim).health = 50
	var press: int = _server().get_tick() + 3
	npc_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	var dead: bool = await _rig.advance_until(func() -> bool: return _combatant(victim).is_dead(), 120, 2)
	assert_true(dead, "an NPC's killing blow kills")
	assert_eq(_events_of(DOWNED).size(), 0, "without a knock-down")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, victim)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, npc)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, NetMessages.EntityEvent.HIT_FLAG_LETHAL)


func test_an_npc_prefers_a_downed_player_and_finishes_it_with_damage() -> void:
	await _rig.start_flat(tree)
	# A loose Hollow facing -Z, a knocked-down player 4 m in front and another standing closer (2.5 m, to one side).
	var definition: NpcDefinition = NpcCatalog.get_definition(&"hollow")
	var hollow_brain := HfsmBrain.new(7)
	var hollow: int = _server().add_npc(hollow_brain, definition.display_name, HUECOS, Vector3.ZERO, 0.0, false,
			definition)
	hollow_brain.bind(_rig.npcs().get_world(), _rig.entity(hollow), _combatant(hollow), definition, Vector3.ZERO,
			0.0)
	var downed: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, -4.0), PI, Plan.new())
	var standing: int = _scripted(SOLMARCH, Vector3(1.5, 0.05, -2.0), PI, Plan.new())
	assert_true(_server().get_combat().down(_combatant(downed), _server().get_tick() + 1))
	var down_tick: int = _server().get_tick() + 1
	var finished: bool = await _rig.advance_until(func() -> bool: return _combatant(downed).is_dead(), 1100, 6)
	assert_true(finished, "the Hollow finishes them off before they bleed out")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, downed)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, hollow, "at the hands of the Hollow")
		assert_true(deaths[0].tick < down_tick + 1200, "before bleeding out")
	var hollow_hits: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events_of(HIT):
		if event.attacker == hollow:
			hollow_hits.append(event)
	if assert_true(not hollow_hits.is_empty(), "hits them"):
		assert_eq(hollow_hits[0].net_id, downed, "the first hit is for the knocked-down player, not the standing one")
		var on_downed: int = 0
		for event: NetMessages.EntityEvent in hollow_hits:
			if event.net_id == downed:
				on_downed += event.amount
		assert_true(on_downed > 0, "with damage (%d)" % on_downed)
	assert_true(_combatant(standing).is_alive())


# --- Command 15 and hits on the same tick -----------------------------------------------------

func test_command_15_downs_without_an_author_and_bleeds_out_without_a_kill() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_safe_area(world, &"vardheim", Vector3(-60.0, 0.0, 0.0), 10.0))
	var ana: int = _scripted(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, Plan.new())
	var safe: int = _scripted(VARDHEIM, Vector3(-60.0, 0.05, 0.0), 0.0, Plan.new())
	var commands: CommandRegistry = _server().get_commands()
	var peer := ServerPeer.new(3)
	peer.entity = _rig.entity(safe)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "in one's own safe zone, no")
	assert_false(_combatant(safe).is_downed())
	# Outside the RVR zones, neither.
	_server().get_combat().downed.zone_id = &"zona_sin_rvr"
	peer.entity = _rig.entity(ana)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "outside an RVR zone, no")
	_server().get_combat().downed.zone_id = &"test_world"
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray([1])),
			CommandRegistry.Result.BAD_ARGUMENTS, "no data")
	var down_tick: int = _server().get_tick() + 1
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.OK, "15")
	assert_true(_combatant(ana).is_downed())
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_DOWN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "already knocked down")
	var downs: Array[NetMessages.EntityEvent] = _events_of(DOWNED, ana)
	if assert_eq(downs.size(), 1):
		assert_eq(downs[0].attacker, 0, "no author")
		assert_eq(downs[0].tick, down_tick)
	await _advance_to(down_tick + 1200)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, ana)
	if assert_eq(deaths.size(), 1, "bleeds out"):
		assert_eq(deaths[0].killer, 0)
		assert_eq(deaths[0].tick, down_tick + 1200)
	assert_eq(_events_of(KILL).size(), 0, "no KILL")
	# Through the console.
	var bo: int = _scripted(SOLMARCH, Vector3(10.0, 0.05, 0.0), 0.0, Plan.new())
	assert_eq(_server().console_command("down %d" % bo), "%s derribado" % _rig.entity(bo).display_name)
	assert_true(_combatant(bo).is_downed())


func test_two_hits_in_the_same_tick_only_the_first_downs_and_the_second_is_dropped() -> void:
	await _rig.start_flat(tree)
	# Two Vardheim attackers on the sides of the Solmarch victim, both hit on the same tick.
	var left_plan := Plan.new()
	var right_plan := Plan.new()
	var left: int = _scripted(VARDHEIM, Vector3(-1.5, 0.05, -1.5), -PI * 0.5, left_plan)
	var right: int = _scripted(VARDHEIM, Vector3(1.5, 0.05, -1.5), PI * 0.5, right_plan)
	var victim: int = _scripted(SOLMARCH, Vector3(0.0, 0.05, -1.5), 0.0, Plan.new())
	_combatant(victim).health = 50
	var press: int = _server().get_tick() + 3
	left_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	right_plan.hold(PlayerInput.PRIMARY, press, press + 2)
	var downed: bool = await _rig.advance_until(func() -> bool: return _combatant(victim).is_downed(), 120, 2)
	assert_true(downed)
	await _rig.advance(4)
	var hits: Array[NetMessages.EntityEvent] = _events_of(HIT, victim)
	if assert_eq(hits.size(), 1, "the second hit of the same tick is discarded"):
		assert_eq(hits[0].attacker, left, "the one with the lower net_id wins")
	assert_eq(_combatant(victim).downed_by, left)
	assert_true(right > left)
	# The later hits do take off knocked-down health, without controls.
	right_plan.hold(PlayerInput.PRIMARY, _server().get_tick() + 40, _server().get_tick() + 42)
	var hit_again: bool = await _rig.advance_until(func() -> bool:
		return _events_of(HIT, victim).size() >= 2, 120, 2)
	assert_true(hit_again)
	var later: NetMessages.EntityEvent = _events_of(HIT, victim)[1]
	assert_eq(later.attacker, right)
	assert_eq(later.hit_flags & NetMessages.EntityEvent.HIT_FLAG_DOWNED, 0)
	assert_eq(_combat_of(victim).action, CombatState.Action.DOWNED, "no stagger")
	assert_true(_combatant(victim).downed_health <= 400 - later.amount)


# --- ENet --------------------------------------------------------------------------------------

func _start_net_server() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = "test_world"
	config.max_players = 8
	config.no_dummies = true
	_net_server = NetHarness.start_server(_server_viewport, config)
	assert_not_null(_net_server, "the server listens")
	_net_server.set_meta(&"port", port)
	await wait_physics_frames(3)


func _join_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(tree.root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, int(_net_server.get_meta(&"port")), realm, bot_seed)
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if client.get_net_id() > 0 and _net_server.get_combat().get_combatant(client.get_net_id()) != null:
			return client
	return null
