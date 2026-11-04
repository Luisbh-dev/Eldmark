extends TestCase
## Tests for the [StatusSystem] inside the [CombatDirector] (docs/habilidades.md, sections 4.1 and 4.3; CMB-20,
## package H3a): a bleed does exactly N pulses at [code]anchor + 60k[/code], stacking, refreshing and
## the strongest, healing over time, a pulse does not interrupt, a pulse that knocks down (or kills, if the
## author is not a player of another realm) in the middle of the list does not change what is iterated, cleanup on death, on
## being knocked down, on respawn and when the author leaves, STATUS with its
## [code]until_tick[/code], movement slots with the same end and the damage and
## mitigation modifiers.
## [br][br]
## No network or server: fighters set up by hand and the director advanced tick by tick with
## [method CombatDirector.process_tick], like test_combat_director.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const STATUS: int = NetMessages.EntityEvent.Kind.STATUS
const HEAL: int = NetMessages.EntityEvent.Kind.HEAL
const DEATH: int = NetMessages.EntityEvent.Kind.DEATH
const KILL: int = NetMessages.EntityEvent.Kind.KILL
const APPLIED: int = NetMessages.EntityEvent.StatusOp.APPLIED
const REMOVED: int = NetMessages.EntityEvent.StatusOp.REMOVED

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
# Test effects added to the catalog's tables (removed in after_each).
var _injected: int = 0


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, SafeAreas.new(),
			CombatFixture.place, _pick_spawn)
	_events.clear()
	_involved.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))
	await wait_physics_frames(3)


func after_each() -> void:
	var statuses: Array[StatusTicks] = CombatCatalog.tables().statuses
	while _injected > 0:
		statuses.pop_back()
		_injected -= 1
	_director = null
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _pick_spawn(realm: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(100.0 + float(realm), 0.0, 100.0))


## A fighter "in combat" from S (until S + 600): without natural health regeneration, which would
## muddy the pulse counts.
func _body(net_id: int, realm: int, position: Vector3, yaw: float = 0.0) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	var combatant: Combatant = _director.add(entity, CombatFixture.make_queue(yaw), null)
	combatant.mark_combat(S)
	return combatant


func _status_id(status_name: StringName) -> int:
	var id: int = CombatCatalog.status_id(status_name)
	assert_true(id > 0, "effect %s exists" % status_name)
	return id


## Advances the director from [param from_tick] to [param to_tick], both included.
func _run(from_tick: int, to_tick: int) -> void:
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	for tick: int in range(from_tick, to_tick + 1):
		_director.process_tick(tick, space)


func _events_of(kind: int, net_id: int = -1) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind and (net_id < 0 or event.net_id == net_id):
			found.append(event)
	return found


func _ticks_of(events: Array[NetMessages.EntityEvent]) -> Array[int]:
	var ticks: Array[int] = []
	for event: NetMessages.EntityEvent in events:
		ticks.append(event.tick)
	return ticks


func _combat_of(combatant: Combatant) -> CombatState:
	return combatant.get_character().combat


## Adds to the catalog's tables a test effect of [param kind] with [param magnitude] and returns its
## id (after_each removes it).
func _inject_status(kind: int, magnitude: float) -> int:
	var statuses: Array[StatusTicks] = CombatCatalog.tables().statuses
	var custom := StatusTicks.new()
	custom.id = statuses.size() + 1
	custom.name = &"prueba_%d" % custom.id
	custom.kind = kind
	custom.duration_ticks = 600
	custom.stacking = StatusEffectDefinition.Stacking.REFRESH
	custom.max_stacks = 1
	custom.pulse_ticks = 60
	custom.magnitude = magnitude
	statuses.append(custom)
	_injected += 1
	return custom.id


# --- Pulses -----------------------------------------------------------------------------------

func test_a_bleed_does_exactly_six_pulses_at_the_anchor_plus_sixty_k() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var data: StatusTicks = CombatCatalog.status(bleed)
	assert_eq([data.duration_ticks, data.pulse_ticks, data.pulse_amount], [360, 60, 15], "6 s bleed")
	assert_true(_director.status.apply(victim, bleed, author.get_id(), S), "it is applied")
	var applied: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	if assert_eq(applied.size(), 1, "STATUS 1 on applying it"):
		assert_eq(applied[0].op, APPLIED)
		assert_eq(applied[0].status_id, bleed)
		assert_eq(applied[0].source_entity, 1, "with its author")
		assert_eq(applied[0].stacks, 1)
		assert_eq(applied[0].until_tick, S + 360, "and its end")
		assert_eq(applied[0].tick, S)
		assert_eq(_involved[0], PackedInt32Array([2, 1]), "the affected one and the author")
	_run(S, S + 500)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	assert_eq(_ticks_of(pulses), [S + 60, S + 120, S + 180, S + 240, S + 300, S + 360],
			"exactly 6 pulses, at anchor + 60k")
	var source: int = CombatSource.make(CombatSource.Kind.STATUS, bleed)
	for pulse: NetMessages.EntityEvent in pulses:
		assert_eq(pulse.amount, 15, "15 per pulse")
		assert_eq(pulse.attacker, 1, "the effect's author is the attacker")
		assert_eq(pulse.get_source(), source, "with the effect's source")
		assert_eq(pulse.damage_type, DamageFormula.DamageType.SLASH, "slashing")
		assert_eq(pulse.hit_flags, 0, "no crit, block or interruption")
	assert_eq(victim.health, 1000 - 90, "90 health in total")
	assert_eq(victim.ledger.damage_by(1, S + 400), 90, "the damage ledger credits it to the author")
	assert_true(author.is_in_combat(S + 360) and victim.is_in_combat(S + 360), "the pulses are combat")
	# The last pulse and the expiry fall on the same tick: the pulse first.
	var statuses: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	if assert_eq(statuses.size(), 2, "applied and removed"):
		assert_eq(statuses[1].op, REMOVED)
		assert_eq(statuses[1].tick, S + 360, "it is removed on expiry")
		assert_eq(statuses[1].stacks, 0)
		assert_true(_events.find(pulses[5]) < _events.find(statuses[1]), "the last pulse before the expiry")
	assert_true(victim.effects.is_empty(), "no longer carries it")
	assert_eq(_director.stats[&"pulse_hits"], 6)


func test_a_pulse_goes_to_the_combat_log_with_the_name_of_its_effect() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var path: String = NetHarness.build_path("test_status_effects_log.csv")
	_director.combat_log = FileAccess.open(path, FileAccess.WRITE)
	_director.status.apply(victim, _status_id(&"bleed"), author.get_id(), S)
	_run(S + 1, S + 60)
	_director.combat_log.close()
	_director.combat_log = null
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).strip_edges().split("\n")
	if assert_eq(lines.size(), 1, "one line, the pulse's"):
		assert_eq(lines[0], "%d,1,2,bleed,%d.00,0.00,pulse,15" % [S + 60, S + 60],
				"tick, author, affected one, effect name, pulse result and damage")


func test_stacking_refreshing_and_the_strongest() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var status: StatusSystem = _director.status
	# STACK (bleed, up to 3): each application adds one and extends the end; the anchor does not change.
	var bleed: int = _status_id(&"bleed")
	for tick: int in [S, S + 30, S + 45, S + 50]:
		status.apply(victim, bleed, author.get_id(), tick)
	var effect: StatusSystem.ActiveEffect = status.find(victim, bleed)
	assert_eq([effect.stacks, effect.anchor_tick, effect.until_tick], [3, S, S + 50 + 360],
			"three stacks at most, anchor of the first, end of the last")
	var stacked: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	assert_eq(stacked.map(func(event: NetMessages.EntityEvent) -> int: return event.stacks), [1, 2, 3, 3])
	_run(S + 51, S + 60)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	if assert_eq(pulses.size(), 1, "the first pulse, at S + 60"):
		assert_eq(pulses[0].amount, 45, "15 per stack")
	# REFRESH (potion healing): renewing extends the end without moving the anchor: more pulses.
	var healed: Combatant = _body(3, VARDHEIM, Vector3(10.0, 0.0, 0.0))
	healed.health = 100
	var regen: int = _status_id(&"potion_regen")
	status.apply(healed, regen, healed.get_id(), S + 100)
	status.apply(healed, regen, healed.get_id(), S + 200)
	var renewed: StatusSystem.ActiveEffect = status.find(healed, regen)
	assert_eq([renewed.anchor_tick, renewed.until_tick, renewed.stacks], [S + 100, S + 200 + 180, 1])
	_run(S + 61, S + 400)
	var heals: Array[NetMessages.EntityEvent] = _events_of(HEAL, 3)
	assert_eq(heals.size(), 9, "pulses every 30 ticks from the anchor to the renewed end")
	assert_eq(heals[0].tick, S + 130)
	assert_eq(heals[8].tick, S + 370)
	for heal: NetMessages.EntityEvent in heals:
		assert_eq(heal.amount, 50)
		assert_eq(heal.healer, 0, "it heals itself: healer 0")
		assert_eq(heal.get_source(), CombatSource.make(CombatSource.Kind.STATUS, regen))
	assert_eq(healed.health, 100 + 9 * 50)
	# STRONGEST (slow): the same effect is equally strong; it keeps the later end, and the
	# movement slot with it.
	var slowed: int = _status_id(&"slowed")
	status.apply(victim, slowed, author.get_id(), S + 500)
	status.apply(victim, slowed, author.get_id(), S + 560)
	var slow: StatusSystem.ActiveEffect = status.find(victim, slowed)
	assert_eq([slow.stacks, slow.anchor_tick, slow.until_tick], [1, S + 500, S + 560 + 180])
	var combat: CombatState = _combat_of(victim)
	assert_eq(combat.move_effect_ids[0], slowed, "the slow takes a movement slot")
	assert_eq(combat.move_effect_until[0], S + 740, "with the same end as the effect")


func test_a_healing_pulse_never_goes_over_the_maximum() -> void:
	var drinker: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	drinker.health = 980
	_director.status.apply(drinker, _status_id(&"potion_regen"), drinker.get_id(), S)
	_run(S, S + 200)
	assert_eq(drinker.health, 1000, "without exceeding the maximum")
	var heals: Array[NetMessages.EntityEvent] = _events_of(HEAL, 1)
	if assert_eq(heals.size(), 1, "only the first pulse heals anything"):
		assert_eq(heals[0].amount, 20, "what it actually heals")


func test_a_pulse_does_not_interrupt_drinking() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var drinker: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	_director.status.apply(drinker, _status_id(&"bleed"), author.get_id(), S)
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var combat: CombatState = _combat_of(drinker)
	combat.action = CombatState.Action.ABILITY
	combat.action_id = potion.id
	combat.action_tick = S + 50
	assert_true(CombatDirector.is_interruptible(combat, S + 60), "at S + 60 it is drinking (cast)")
	_run(S + 1, S + 60)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	if assert_eq(pulses.size(), 1):
		assert_false(pulses[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "without bit 5")
	assert_eq(combat.action, CombatState.Action.ABILITY, "still drinking: a pulse does not interrupt")
	assert_eq(_director.stats[&"interrupts"], 0)


## H3c (docs/habilidades.md, section 4.5): the lethal pulse of a player of another realm knocks down; effects are
## removed on being knocked down (DOWNED clears them on the client) and that tick's healing is no longer applied.
func test_a_pulse_that_downs_in_the_middle_of_the_list_does_not_change_what_is_walked() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var first: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var second: Combatant = _body(3, SOLMARCH, Vector3(3.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var regen: int = _status_id(&"potion_regen")
	var slowed: int = _status_id(&"slowed")
	first.health = 500
	_director.status.apply(first, bleed, author.get_id(), S)
	_director.status.apply(first, regen, first.get_id(), S)
	_director.status.apply(first, slowed, author.get_id(), S)
	_director.status.apply(second, bleed, author.get_id(), S)
	_run(S + 1, S + 59)
	first.health = 10
	_events.clear()
	_run(S + 60, S + 60)
	assert_true(first.is_downed(), "the bleed of the other realm's player knocks them down")
	assert_false(first.is_dead() or first.is_alive(), "a knocked-down player is neither alive nor dead")
	assert_eq(_events_of(HEAL, 2).size(), 0, "and their healing from that same tick is no longer applied")
	assert_true(first.effects.is_empty(), "knocked down, with no effects")
	assert_eq(_combat_of(first).move_effect_ids, PackedInt32Array([0, 0]), "nor movement slots")
	assert_eq(_combat_of(first).action, CombatState.Action.DOWNED)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	if assert_eq(pulses.size(), 1, "the pulse"):
		assert_eq(pulses[0].hit_flags, NetMessages.EntityEvent.HIT_FLAG_DOWNED, "with bit 6 (knocks down)")
	var downs: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.DOWNED, 2)
	if assert_eq(downs.size(), 1, "DOWNED"):
		assert_eq(downs[0].attacker, 1, "the bleed's author knocks them down")
		assert_eq(downs[0].get_source(), CombatSource.make(CombatSource.Kind.STATUS, bleed))
	assert_eq(_events_of(DEATH, 2).size(), 0, "no DEATH")
	assert_eq(_events_of(STATUS, 2).size(), 0, "no loose STATUS: DOWNED clears them on the client")
	assert_eq(_events_of(HIT, 3).size(), 1, "the next one in the list gets its pulse")
	assert_eq(second.health, 1000 - 15)
	assert_false(_director.status.apply(first, bleed, author.get_id(), S + 61), "no effects are applied to a knocked-down player")
	_run(S + 61, S + 130)
	assert_eq(_events_of(HIT, 2).size(), 1, "nor does it pulse")


func test_a_lethal_pulse_in_the_middle_of_the_list_does_not_change_what_is_walked() -> void:
	# The author is an NPC: its lethal pulse kills without knocking down (docs/habilidades.md, section 4.5).
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	author.entity.kind = NetProtocol.EntityKind.NPC
	var first: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var second: Combatant = _body(3, SOLMARCH, Vector3(3.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var regen: int = _status_id(&"potion_regen")
	assert_true(bleed < regen, "the bleed goes before the healing (by id)")
	# The first carries bleed and healing anchored at S: both pulse at S + 60 and the bleed, which goes
	# first, kills it.
	first.health = 500
	_director.status.apply(first, bleed, author.get_id(), S)
	_director.status.apply(first, regen, first.get_id(), S)
	_director.status.apply(second, bleed, author.get_id(), S)
	_run(S + 1, S + 59)
	assert_eq(_events_of(HEAL, 2).size(), 1, "the healing pulses at S + 30")
	assert_eq(first.health, 550)
	first.health = 10
	_events.clear()
	_run(S + 60, S + 60)
	assert_true(first.is_dead(), "the bleed kills it")
	assert_eq(_events_of(HEAL, 2).size(), 0, "and its healing from that same tick is no longer applied")
	assert_true(first.effects.is_empty(), "dead, with no effects")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, 2)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, 1, "the bleed's author kills it")
		assert_eq(deaths[0].get_source(), CombatSource.make(CombatSource.Kind.STATUS, bleed))
	assert_eq(_events_of(KILL, 2).size(), 1, "with its KILL")
	assert_eq(_events_of(STATUS, 2).size(), 0, "no loose STATUS: DEATH clears them on the client")
	var second_pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 3)
	assert_eq(second_pulses.size(), 1, "the next one in the list gets its pulse")
	assert_eq(second.health, 1000 - 15)


# --- Cleanup ----------------------------------------------------------------------------------

func test_effects_are_cleared_on_death_and_on_respawn_without_status_events() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var slowed: int = _status_id(&"slowed")
	_director.status.apply(victim, _status_id(&"bleed"), author.get_id(), S)
	_director.status.apply(victim, slowed, author.get_id(), S)
	assert_eq(_combat_of(victim).move_effect_ids[0], slowed)
	_events.clear()
	_director.kill(victim, S + 10)
	assert_true(victim.effects.is_empty(), "on death all are removed")
	assert_eq(_combat_of(victim).move_effect_ids, PackedInt32Array([0, 0]), "the movement slots too")
	assert_eq(_events_of(STATUS).size(), 0, "no loose STATUS")
	# An effect that is not applied to a dead player.
	assert_false(_director.status.apply(victim, slowed, author.get_id(), S + 20), "not to a dead one")
	# On respawn it starts clean (and with empty slots).
	_director.request_respawn(2, 0, victim.respawn_tick)
	_run(victim.respawn_tick, victim.respawn_tick)
	assert_true(victim.is_alive(), "has respawned")
	assert_true(victim.effects.is_empty())
	assert_eq(_events_of(STATUS).size(), 0)


func test_effects_of_an_author_that_leaves_are_removed_with_status_two() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var slowed: int = _status_id(&"slowed")
	var regen: int = _status_id(&"potion_regen")
	_director.status.apply(victim, bleed, author.get_id(), S)
	_director.status.apply(victim, slowed, author.get_id(), S)
	_director.status.apply(victim, regen, victim.get_id(), S)
	# The author also carries an effect of its own: it goes away with them, without events.
	_director.status.apply(author, regen, author.get_id(), S)
	_events.clear()
	_director.remove(author.get_id(), S + 10)
	var removed: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	assert_eq(removed.size(), 2, "STATUS 2 for the two effects it applied")
	for event: NetMessages.EntityEvent in removed:
		assert_eq(event.op, REMOVED)
		assert_eq(event.tick, S + 10, "on the departure tick")
		assert_eq(event.source_entity, 1)
	assert_eq(removed.map(func(event: NetMessages.EntityEvent) -> int: return event.status_id), [bleed, slowed])
	assert_eq(victim.effects.size(), 1, "its own healing continues")
	assert_eq(victim.effects[0].status_id, regen)
	assert_eq(_combat_of(victim).move_effect_ids, PackedInt32Array([0, 0]), "and the slow's slot is emptied")
	assert_eq(_events_of(STATUS, 1).size(), 0, "nothing comes out for the one leaving")
	# There are no more orphaned pulses.
	_run(S + 11, S + 120)
	assert_eq(_events_of(HIT, 2).size(), 0)



## Phase 4 review ("abilities" lens): a STRONGEST (slow) renewed by another author with a later end
## becomes theirs, like REFRESH and STACK: the renewal's STATUS carries its source_entity (and reaches
## them as involved), and the first one's departure no longer removes what the second sustains; the second's does.
## Renewing without extending the end does not change the author.
func test_a_strongest_renewed_by_another_author_belongs_to_whoever_holds_the_latest_end() -> void:
	_body(1, VARDHEIM, Vector3.ZERO)
	_body(3, VARDHEIM, Vector3(3.0, 0.0, 0.0))
	var victim: Combatant = _body(20, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var slowed: int = _status_id(&"slowed")
	var data: StatusTicks = CombatCatalog.status(slowed)
	assert_eq(data.stacking, StatusEffectDefinition.Stacking.STRONGEST, "slow is STRONGEST")
	var until: int = S + 60 + data.duration_ticks
	_director.status.apply(victim, slowed, 1, S)
	_director.status.apply(victim, slowed, 3, S + 60)
	var effect: StatusSystem.ActiveEffect = _director.status.find(victim, slowed)
	assert_eq([effect.source_id, effect.until_tick], [3, until], "the second extends the end and becomes the author")
	var applied: Array[NetMessages.EntityEvent] = _events_of(STATUS, 20)
	if assert_eq(applied.size(), 2, "STATUS 1 for both applications"):
		assert_eq(applied[1].source_entity, 3, "the renewal's carries the second")
		assert_eq(applied[1].until_tick, until)
		assert_true(_involved[_events.find(applied[1])].has(3), "and reaches them as involved")
	# An end that is not later (command 14 with a short duration) does not change the author.
	_director.status.apply(victim, slowed, 1, S + 70, 30)
	assert_eq([effect.source_id, effect.until_tick], [3, until], "without extending the end, the author does not change")
	_events.clear()
	_director.remove(1, S + 100)
	assert_eq(_director.status.find(victim, slowed), effect, "the first's departure does not remove what the second sustains")
	assert_eq(_events_of(STATUS, 20).size(), 0, "nor does STATUS 2 go out")
	var combat: CombatState = _combat_of(victim)
	assert_eq([combat.move_effect_ids[0], combat.move_effect_until[0]], [slowed, until], "the slot remains")
	_director.remove(3, S + 110)
	assert_null(_director.status.find(victim, slowed), "the second's departure does")
	var removed: Array[NetMessages.EntityEvent] = _events_of(STATUS, 20)
	if assert_eq(removed.size(), 1, "with STATUS 2"):
		assert_eq([removed[0].op, removed[0].source_entity, removed[0].tick], [REMOVED, 3, S + 110])
	assert_eq(combat.move_effect_ids, PackedInt32Array([0, 0]), "and empties the slot")


# --- Slots and limits -------------------------------------------------------------------------

func test_a_slow_and_a_root_write_their_movement_slots_and_the_ninth_effect_replaces_the_earliest() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var slowed: int = _status_id(&"slowed")
	var rooted: int = _status_id(&"rooted")
	_director.status.apply(victim, slowed, author.get_id(), S)
	_director.status.apply(victim, rooted, author.get_id(), S + 5, 30)
	var combat: CombatState = _combat_of(victim)
	assert_eq(combat.move_effect_ids, PackedInt32Array([slowed, rooted]))
	assert_eq(combat.move_effect_until, PackedInt64Array([S + 180, S + 35]),
			"each slot with its effect's end (the root with the requested duration)")
	var events: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	assert_eq(events[1].until_tick, S + 35, "STATUS with the until_tick of the requested duration")
	# Up to 8 effects: a new one replaces the one that ends earliest (the root), with STATUS 2.
	for index: int in 6:
		_inject_status(StatusEffectDefinition.Kind.DAMAGE_UP, 0.0)
	var first_custom: int = CombatCatalog.tables().statuses.size() - 5
	for index: int in 6:
		_director.status.apply(victim, first_custom + index, author.get_id(), S + 10)
	assert_eq(victim.effects.size(), StatusSystem.MAX_EFFECTS)
	_events.clear()
	var ninth: int = _inject_status(StatusEffectDefinition.Kind.DAMAGE_UP, 0.0)
	_director.status.apply(victim, ninth, author.get_id(), S + 20)
	assert_eq(victim.effects.size(), StatusSystem.MAX_EFFECTS, "there are still 8")
	assert_null(_director.status.find(victim, rooted), "the one that ended earliest is gone")
	var removed: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	if assert_eq(removed.size(), 2, "STATUS 2 of the replaced one and STATUS 1 of the new one"):
		assert_eq([removed[0].op, removed[0].status_id], [REMOVED, rooted])
		assert_eq([removed[1].op, removed[1].status_id], [APPLIED, ninth])
	assert_eq(combat.move_effect_ids, PackedInt32Array([slowed, 0]), "the root's slot is emptied")


func test_damage_up_and_mitigation_down_change_the_damage() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var damage_up: int = _inject_status(StatusEffectDefinition.Kind.DAMAGE_UP, 0.5)
	var mitigation_down: int = _inject_status(StatusEffectDefinition.Kind.MITIGATION_DOWN, -0.25)
	_director.status.apply(attacker, damage_up, attacker.get_id(), S - 10)
	assert_near(_director.status.damage_scale(attacker), 1.5, 0.0001, "1 + Σ DAMAGE_UP")
	assert_near(_director.status.damage_scale(victim), 1.0, 0.0001, "with no effects, 1")
	CombatFixture.start_light_active(attacker, S)
	_run(S, S)
	assert_eq(victim.health, 1000 - 135, "the 90 light attack does 135 with +50 %")
	# While blocking, with MITIGATION_DOWN of 0.25 the shield only absorbs 75 %.
	victim.heal_full()
	_director.status.apply(victim, mitigation_down, attacker.get_id(), S + 90)
	assert_near(_director.status.mitigation_penalty(victim), 0.25, 0.0001, "Σ MITIGATION_DOWN, in absolute value")
	CombatFixture.start_block(victim, S + 50)
	CombatFixture.start_light_active(attacker, S + 100)
	attacker.forget_swing()
	_run(S + 100, S + 100)
	# Gross 135; absorbs 135 × 0.75 = 101.25; 33.75 gets through → 34.
	assert_eq(victim.health, 1000 - 34, "what the shield no longer absorbs gets through")
