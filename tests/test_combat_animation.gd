extends TestCase
## Tests of the combat animation layer (ART-08) and of the provisional weapons (ART-06).
## [br]- The clip resource ([CombatClipSet]) resolves all its UAL1/UAL2 clips.
## [br]- [CombatClipPlanner] picks the right clip for each action and the playback speed
## that fits each phase to its duration in the combat data.
## [br]- The contact frame of each attack falls within its active window (with a one-tick margin).
## [br]- Reconciliation (replaying ticks) does not restart the clips; a remote is animated with the
## action byte; the [CombatPoseModifier] sets the pose only on the bones it touches.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CLIPS_PATH: String = "res://data/animation/sword_shield_clips.tres"
const START_TICK: int = 1000
const PRIMARY: int = PlayerInput.PRIMARY
const BLOCK: int = PlayerInput.BLOCK
const DODGE: int = PlayerInput.DODGE

var _clips: CombatClipSet
var _weapon: WeaponTicks
var _tick_rate: float = 60.0
var _nodes: Array[Node] = []
var _server_viewport: SubViewport = null
var _server_world: Node3D = null


func before_each() -> void:
	_clips = load(CLIPS_PATH) as CombatClipSet
	_weapon = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	_tick_rate = float(Engine.physics_ticks_per_second)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	_server_viewport = null
	_server_world = null
	await wait_process_frames()


## Physics-free action machine: a [CombatState] and a clock, to script buttons tick by tick.
class Driver:
	var c: CombatState
	var tick: int = START_TICK
	var move: Vector2 = Vector2.ZERO

	func _init() -> void:
		c = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())

	func step(buttons: int = 0) -> void:
		tick += 1
		var input := PlayerInput.new()
		input.tick = tick
		input.buttons = buttons
		input.move = move
		ActionMachine.step(c, input, true)


func _attack(attack_name: StringName) -> AttackTicks:
	return CombatCatalog.attack(CombatCatalog.attack_id(attack_name))


# --- The clip resource ----------------------------------------------------------------------

func test_clip_set_covers_every_attack_and_action() -> void:
	if not assert_not_null(_clips, "the resource loads"):
		return
	for key: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3", &"sword_heavy",
			&"charge", &"block", &"dodge", &"stagger", &"stun", &"dead"]:
		assert_not_null(_clips.find(key), "there is an entry for %s" % key)
	assert_null(_clips.find(&"no_existe"))
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3",
			&"sword_heavy"]:
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		assert_true(entry.is_attack(), "%s has the three segments" % name_of_attack)
		assert_true(entry.upper_body, "and is animated on the upper body")


func test_every_segment_points_into_an_existing_clip() -> void:
	var checked: int = 0
	for entry: CombatActionAnim in _clips.entries:
		for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
			if segment == null:
				continue
			var animation: Animation = _clips.get_animation(segment.animation)
			if not assert_not_null(animation, "%s: the clip %s exists" % [entry.key, segment.animation]):
				continue
			checked += 1
			assert_true(segment.from_s >= 0.0 and segment.to_s <= animation.length + 0.0001,
					"%s: [%.3f, %.3f] fits in %s (%.3f s)" % [entry.key, segment.from_s,
					segment.to_s, segment.animation, animation.length])
			assert_true(segment.to_s > segment.from_s, "%s: the segment advances" % entry.key)
	assert_true(checked >= 18, "%d segments were checked" % checked)
	assert_null(_clips.get_animation(&"ual9/Nada"), "an unknown library does not resolve")
	assert_null(_clips.get_animation(&"ual1/NoExiste"))
	assert_null(_clips.get_animation(&"sin_barra"))


# --- Clip selection -------------------------------------------------------------------------

func test_planner_picks_the_right_clip_for_each_action() -> void:
	var expected: Array[Array] = [
		# action, phase, combo step, clip, upper body
		[CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 0, &"ual2/Sword_Regular_A", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_ACTIVE, 0, &"ual2/Sword_Regular_A", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 0, &"ual2/Sword_Regular_A_Rec", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 1, &"ual2/Sword_Regular_B", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 1, &"ual2/Sword_Regular_B_Rec", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 2, &"ual2/Sword_Regular_C", true],
		[CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 2, &"ual2/Sword_Regular_C", true],
		[CombatState.Action.HEAVY, ActionMachine.PHASE_WINDUP, 0, &"ual2/Sword_Heavy_Combo", true],
		[CombatState.Action.HEAVY, ActionMachine.PHASE_ACTIVE, 0, &"ual2/Sword_Heavy_Combo", true],
		[CombatState.Action.CHARGE, ActionMachine.PHASE_WINDUP, 0, &"ual2/Sword_Heavy_Combo", true],
		[CombatState.Action.BLOCK, ActionMachine.PHASE_NONE, 0, &"ual2/Idle_Shield_Loop", true],
		[CombatState.Action.DODGE, ActionMachine.PHASE_NONE, 0, &"ual1/Roll", false],
		[CombatState.Action.STAGGER, ActionMachine.PHASE_NONE, 0, &"ual1/Hit_Chest", false],
		[CombatState.Action.STUN, ActionMachine.PHASE_NONE, 0, &"ual2/Idle_Shield_Break", true],
		[CombatState.Action.DEAD, ActionMachine.PHASE_NONE, 0, &"ual1/Death01", false],
	]
	for row: Array in expected:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, int(row[0]),
				int(row[1]), int(row[2]), 0.0)
		var label: String = "acción %d fase %d paso %d" % [int(row[0]), int(row[1]), int(row[2])]
		if not assert_not_null(plan, "%s has an animation" % label):
			continue
		assert_eq(plan.animation, row[3], "%s: clip" % label)
		assert_eq(plan.upper_body, bool(row[4]), "%s: upper body" % label)
	assert_null(CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.NONE, 3, 0, 0.0),
			"without an action there is no combat animation")
	assert_null(CombatClipPlanner.plan(null, _weapon, CombatState.Action.LIGHT, 0, 0, 0.0))


func test_planner_keys_follow_the_catalog_names() -> void:
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.LIGHT, 0), &"sword_light_1")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.LIGHT, 2), &"sword_light_3")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.LIGHT, 9), &"sword_light_3",
			"an out-of-range step is clamped")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.HEAVY, 0), &"sword_heavy")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.NONE, 0), &"")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.DODGE, 0), &"dodge")


# --- Playback speed ----------------------------------------------------------------

func test_each_attack_phase_is_stretched_to_its_duration() -> void:
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3",
			&"sword_heavy"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		var action: int = CombatState.Action.HEAVY if attack.heavy else CombatState.Action.LIGHT
		var combo: int = _weapon.light_index(attack.id) if not attack.heavy else 0
		var lengths: Array[int] = [attack.windup_ticks, attack.active_ticks, attack.recovery_ticks]
		for phase: int in 3:
			var segment: CombatClipSegment = entry.segment_for_phase(phase)
			var seconds: float = float(lengths[phase]) / _tick_rate
			var start: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, 0.0)
			assert_near(start.time_s, segment.from_s, 0.0001, "%s phase %d: starts at the beginning of the segment" % [name_of_attack, phase])
			assert_near(start.speed * seconds, segment.length_s(), 0.0001,
					"%s phase %d: the speed (%.3f) covers the segment in the phase's duration" % [name_of_attack, phase, start.speed])
			assert_near(start.duration_s, seconds, 0.0001)
			var middle: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, float(lengths[phase]) * 0.5)
			assert_near(middle.time_s, (segment.from_s + segment.to_s) * 0.5, 0.0001,
					"%s phase %d: halfway through the phase, halfway through the segment" % [name_of_attack, phase])
			var finish: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, float(lengths[phase]))
			assert_near(finish.time_s, segment.to_s, 0.0001, "%s phase %d: ends at the end of the segment" % [name_of_attack, phase])
			var beyond: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action,
					phase, combo, float(lengths[phase]) * 3.0)
			assert_near(beyond.time_s, segment.to_s, 0.0001, "%s phase %d: does not go past the end" % [name_of_attack, phase])


func test_dodge_and_controls_fit_their_durations() -> void:
	var dodge_ticks: int = _weapon.dodge.duration_ticks
	var dodge: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon,
			CombatState.Action.DODGE, ActionMachine.PHASE_NONE, 0, 0.0)
	var roll: CombatClipSegment = _clips.find(&"dodge").windup
	assert_near(dodge.duration_s, float(dodge_ticks) / _tick_rate, 0.0001, "the dodge lasts what the data says")
	assert_near(dodge.speed * dodge.duration_s, roll.length_s(), 0.0001)
	var end: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DODGE,
			ActionMachine.PHASE_NONE, 0, float(dodge_ticks))
	assert_near(end.time_s, roll.to_s, 0.0001)
	# An 18-tick stagger: the clip is stretched to those 0.3 s.
	var stagger: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon,
			CombatState.Action.STAGGER, ActionMachine.PHASE_NONE, 0, 0.0, 18)
	assert_near(stagger.duration_s, 18.0 / _tick_rate, 0.0001)
	var stagger_clip: CombatClipSegment = _clips.find(&"stagger").windup
	assert_near(stagger.speed * stagger.duration_s, stagger_clip.length_s(), 0.0001)
	# With no known duration (a remote) it uses the resource's.
	var remote: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon,
			CombatState.Action.STAGGER, ActionMachine.PHASE_NONE, 0, 0.0)
	assert_near(remote.duration_s, _clips.find(&"stagger").duration_s, 0.0001)


func test_charge_and_death_hold_their_last_pose() -> void:
	for pair: Array in [[CombatState.Action.CHARGE, &"charge"], [CombatState.Action.DEAD, &"dead"]]:
		var entry: CombatActionAnim = _clips.find(pair[1])
		assert_true(entry.hold_end, "%s stays on the last pose" % pair[1])
		var late: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, int(pair[0]),
				ActionMachine.PHASE_NONE, 0, 100000.0)
		# The charge breathes (ART-07): it sways up to sway_s backward through its segment and returns.
		assert_true(late.time_s <= entry.windup.to_s + 0.0001 and late.time_s >= entry.windup.to_s - entry.sway_s - 0.0001,
				"%s: long after, it is still at the end (%.3f)" % [pair[1], late.time_s])
		assert_true(late.hold)


## ART-48: the block is the shield guard on a loop (not a frozen pose): the shield stays in front of the
## chest, the clip does not stand still and you can walk while blocking (upper body only).
func test_block_loops_the_shield_guard_instead_of_freezing() -> void:
	var entry: CombatActionAnim = _clips.find(&"block")
	assert_true(entry.loop, "the block repeats")
	assert_false(entry.hold_end, "and does not stay on the last pose")
	assert_true(entry.upper_body, "upper body only: you walk while blocking")
	assert_eq(entry.windup.animation, &"ual2/Idle_Shield_Loop")
	var length: float = _clips.get_animation(entry.windup.animation).length
	assert_near(entry.windup.length_s(), length, 0.0001, "the full loop of the clip")
	var times: Array[float] = []
	for ticks: float in [0.0, 40.0, 80.0, 120.0]:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
				ActionMachine.PHASE_NONE, 0, ticks)
		assert_false(plan.hold)
		assert_near(plan.speed, 1.0, 0.0001, "at its original speed")
		times.append(plan.time_s)
	assert_true(times[1] > times[0] and times[2] > times[1] and times[3] > times[2], "the instant advances")
	var wrapped: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
			ActionMachine.PHASE_NONE, 0, entry.duration_s * _tick_rate + 30.0)
	assert_near(wrapped.time_s, entry.windup.from_s + 30.0 / _tick_rate, 0.0001, "and goes back to the start")
	# The shield wall keeps the same guard on a loop.
	var wall: CombatActionAnim = _clips.find(&"shield_wall")
	assert_true(wall.loop and not wall.hold_end, "the shield wall does not freeze the clip either")
	assert_eq(wall.windup.animation, &"ual2/Idle_Shield_Loop")


## ART-49: the dodge plays the trimmed Roll at about 2x at most (the only clip there is; the cap of the
## quality bar for the dodge), not at 3x.
func test_the_dodge_clip_plays_at_most_twice_as_fast() -> void:
	for clips: CombatClipSet in [_clips, load(BOW_CLIPS_PATH) as CombatClipSet]:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(clips, _weapon, CombatState.Action.DODGE,
				ActionMachine.PHASE_NONE, 0, 0.0)
		assert_true(plan.speed <= 2.0001 and plan.speed >= 0.7, "dodge at %.2fx" % plan.speed)


# --- Contact inside the active window -----------------------------------------------------

func test_contact_frame_falls_inside_the_active_window() -> void:
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3",
			&"sword_heavy"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		var contact: float = CombatClipPlanner.contact_tick(entry, attack)
		assert_true(contact >= float(attack.active_from()) - 1.0
				and contact <= float(attack.active_to()) + 1.0,
				"%s: the contact (tick %.1f) falls in the active window [%d, %d) +-1" % [
				name_of_attack, contact, attack.active_from(), attack.active_to()])
		assert_true(entry.contact_s >= entry.active.from_s and entry.contact_s <= entry.active.to_s,
				"%s: the contact is inside the clip's active segment" % name_of_attack)
	assert_eq(CombatClipPlanner.contact_tick(_clips.find(&"block"), _attack(&"sword_light_1")), -1.0,
			"what is not an attack has no contact")


func test_layer_reaches_the_contact_frame_within_the_active_window_for_each_light() -> void:
	for name_of_attack: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var entry: CombatActionAnim = _clips.find(name_of_attack)
		var driver := Driver.new()
		driver.c.combo_step = _weapon.light_index(attack.id)
		driver.step()
		driver.step(PRIMARY)
		var action_tick: int = driver.c.action_tick
		assert_eq(driver.c.action_id, attack.id, "%s starts" % name_of_attack)
		var layer := CombatAnimationLayer.new(_clips)
		var contact_k: int = -1
		for k: int in attack.total_ticks:
			var tick: int = action_tick + k
			if k > 0:
				driver.step(PRIMARY if k < 3 else 0)
			layer.update_local(driver.c, tick, 0.0, 1.0 / _tick_rate)
			var slot: CombatAnimationLayer.Slot = layer.get_current()
			if contact_k < 0 and slot != null and slot.animation_name == entry.active.animation \
					and layer.get_plan().phase >= ActionMachine.PHASE_ACTIVE \
					and slot.time_s >= entry.contact_s - 0.0001:
				contact_k = k
		assert_true(contact_k >= attack.active_from() - 1 and contact_k <= attack.active_to() + 1,
				"%s: the contact frame comes out on tick %d of the action (active window [%d, %d) +-1)" % [
				name_of_attack, contact_k, attack.active_from(), attack.active_to()])


func test_layer_reaches_the_contact_frame_within_the_active_window_for_the_heavy() -> void:
	var attack: AttackTicks = _attack(&"sword_heavy")
	var entry: CombatActionAnim = _clips.find(&"sword_heavy")
	var driver := Driver.new()
	driver.step()
	var layer := CombatAnimationLayer.new(_clips)
	# Hold PRIMARY: light -> charge -> release -> heavy.
	var released: bool = false
	var heavy_tick: int = -1
	var contact_k: int = -1
	for i: int in 160:
		var holding: bool = i < 8 + attack.charge_min_ticks + 4
		driver.step(PRIMARY if holding else 0)
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
		if driver.c.action == CombatState.Action.HEAVY and heavy_tick < 0:
			heavy_tick = driver.c.action_tick
		if heavy_tick >= 0:
			released = true
			var k: int = driver.tick - heavy_tick
			var slot: CombatAnimationLayer.Slot = layer.get_current()
			if contact_k < 0 and slot != null and slot.key == &"sword_heavy" \
					and layer.get_plan().phase >= ActionMachine.PHASE_ACTIVE \
					and slot.time_s >= entry.contact_s - 0.0001:
				contact_k = k
	assert_true(released, "the heavy attack was actually launched")
	assert_true(contact_k >= attack.active_from() - 1 and contact_k <= attack.active_to() + 1,
			"the heavy: contact on tick %d of the action (window [%d, %d) +-1)" % [
			contact_k, attack.active_from(), attack.active_to()])


func test_layer_shows_charge_then_the_heavy_with_a_crossfade() -> void:
	var driver := Driver.new()
	driver.step()
	var layer := CombatAnimationLayer.new(_clips)
	var keys_seen: Array[StringName] = []
	for i: int in 70:
		driver.step(PRIMARY if i < 35 else 0)
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
		var current: CombatAnimationLayer.Slot = layer.get_current()
		if current != null and (keys_seen.is_empty() or keys_seen[keys_seen.size() - 1] != current.key):
			keys_seen.append(current.key)
	assert_eq(keys_seen, [&"sword_light_1", &"charge", &"sword_heavy"] as Array[StringName],
			"a light attack that turns into a charge and is released as a heavy")


# --- Reconciliation does not restart the clips --------------------------------------------------

func test_replaying_ticks_does_not_restart_the_clip() -> void:
	var driver := Driver.new()
	driver.step()
	var layer := CombatAnimationLayer.new(_clips)
	var snapshots: Array[CombatState] = []
	var inputs: Array[int] = []
	for i: int in 24:
		var buttons: int = PRIMARY if i < 3 else 0
		driver.step(buttons)
		inputs.append(buttons)
		snapshots.append(driver.c.duplicate_state())
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	var slot_before: CombatAnimationLayer.Slot = layer.get_current()
	var time_before: float = slot_before.time_s
	var weight_before: float = slot_before.weight
	assert_true(weight_before > 0.9, "the clip is already at full weight")
	# Reconciliation goes back to the state of tick 12 and replays the same ticks.
	driver.c.copy_from(snapshots[11])
	driver.tick = START_TICK + 1 + 12
	for i: int in range(12, 24):
		driver.step(inputs[i])
	layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	var slot_after: CombatAnimationLayer.Slot = layer.get_current()
	assert_true(slot_after == slot_before, "it is the same clip: it does not restart")
	assert_near(slot_after.time_s, time_before, 0.0001, "at the same instant")
	assert_true(slot_after.weight >= weight_before, "and the weight does not restart")
	assert_null(layer.get_previous(), "no fade back")


func test_a_server_imposed_control_changes_the_key_and_crossfades() -> void:
	var driver := Driver.new()
	driver.step()
	driver.step(PRIMARY)
	var layer := CombatAnimationLayer.new(_clips)
	for i: int in 10:
		driver.step()
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	var attack_slot: CombatAnimationLayer.Slot = layer.get_current()
	assert_eq(attack_slot.key, &"sword_light_1")
	ActionMachine.impose_stagger(driver.c, driver.tick, driver.tick + 20, Vector2.ZERO)
	driver.step()
	layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	assert_true(layer.get_current().key == &"stagger" or layer.get_current().key == &"stagger_short"
			or layer.get_current().key == &"stagger_head", "the imposed stagger changes the clip")
	assert_true(layer.get_previous() == attack_slot, "and the attack fades out")
	assert_true(layer.get_previous().target == 0.0)
	for i: int in 20:
		driver.step()
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	assert_null(layer.get_previous(), "once the fade ends, only the new clip remains")


func test_layer_fades_out_when_the_action_ends() -> void:
	var driver := Driver.new()
	driver.step()
	driver.step(PRIMARY)
	var layer := CombatAnimationLayer.new(_clips)
	var attack: AttackTicks = _attack(&"sword_light_1")
	for i: int in attack.total_ticks + 20:
		driver.step()
		layer.update_local(driver.c, driver.tick, 0.0, 1.0 / _tick_rate)
	assert_eq(driver.c.action, CombatState.Action.NONE, "the attack has ended")
	assert_eq(layer.get_current(), null, "and the layer has emptied after the fade-out")
	assert_true(layer.get_slots().is_empty())
	assert_false(layer.is_active())


# --- Remotes ----------------------------------------------------------------------------------

func _byte(action: int, phase: int, combo: int = 0) -> int:
	return (action & 15) | (phase << 4) | (combo << 6)


func test_remote_action_byte_selects_the_clip_and_restarts_each_phase() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var dt: float = 1.0 / _tick_rate
	layer.update_remote(_byte(CombatState.Action.NONE, ActionMachine.PHASE_NONE), dt)
	assert_null(layer.get_current(), "without an action, nothing")
	# Light 2 in windup.
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 1), dt)
	var slot: CombatAnimationLayer.Slot = layer.get_current()
	assert_eq(slot.key, &"sword_light_2")
	assert_eq(slot.animation_name, &"ual2/Sword_Regular_B")
	var entry: CombatActionAnim = _clips.find(&"sword_light_2")
	assert_near(slot.time_s, entry.windup.from_s, 0.0001, "the segment starts from its beginning")
	for _i: int in 5:
		layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 1), dt)
	assert_true(layer.get_current().time_s > entry.windup.from_s, "and advances with real time")
	# Moves to active hit: the active segment starts from zero, even if it has spent time in the previous phase.
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_ACTIVE, 1), dt)
	assert_eq(layer.get_current().animation_name, &"ual2/Sword_Regular_B")
	assert_near(layer.get_current().time_s, entry.active.from_s, 0.0001)
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_RECOVERY, 1), dt)
	assert_eq(layer.get_current().animation_name, &"ual2/Sword_Regular_B_Rec", "recovery")
	# The next one in the combo (step 2) is another action even if the phase goes back to windup.
	layer.update_remote(_byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 2), dt)
	assert_eq(layer.get_current().key, &"sword_light_3")
	assert_true(layer.get_previous() != null, "with a fade from the previous one")


func test_remote_dead_and_dodge_play_and_hold() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var dt: float = 1.0 / _tick_rate
	layer.update_remote(_byte(CombatState.Action.DODGE, ActionMachine.PHASE_NONE), dt)
	assert_eq(layer.get_current().animation_name, &"ual1/Roll")
	assert_false(layer.get_current().upper_body, "the dodge is full-body")
	for _i: int in 200:
		layer.update_remote(_byte(CombatState.Action.DEAD, ActionMachine.PHASE_NONE), dt)
	var dead: CombatAnimationLayer.Slot = layer.get_current()
	assert_eq(dead.animation_name, &"ual1/Death01")
	assert_near(dead.time_s, _clips.find(&"dead").windup.to_s, 0.0001, "lying down, on the last pose")
	assert_near(dead.weight, 1.0, 0.0001, "at full weight")


func test_remote_ignores_garbage_actions() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	layer.update_remote(0x0F, 0.016)
	assert_null(layer.get_current(), "an action outside the enum is not animated")
	assert_eq(ActionMachine.action_byte(CombatState.initial(CombatCatalog.rules(), 1), 0), 0x30,
			"and the \"no action\" byte is 0x30")
	layer.update_remote(0x30, 0.016)
	assert_null(layer.get_current())


## A server fighter in its own world: it is the one that publishes the action byte the
## other clients see (the real path, not the standalone action machine).
func _make_server_fighter(net_id: int) -> Combatant:
	if _server_world == null:
		_server_viewport = CombatFixture.make_world(tree.root)
		_nodes.append(_server_viewport)
		_server_world = NetHarness.get_world(_server_viewport)
	return CombatFixture.make_fighter(_server_world, net_id, NetProtocol.Realm.VARDHEIM, Vector3.ZERO,
			0.0, CombatTiming.from_rules(CombatCatalog.rules()))


## Walks ticks [code]START_TICK + 1[/code] to [code]START_TICK + last_rel[/code] of the fighter:
## on each one it simulates the action machine with the buttons of [param buttons_at] (relative tick
## -> buttons), calls [param impose] (with the relative tick, to impose controls as the
## server does after resolving hits) and publishes. A remote receives the [code]action[/code] byte of a
## snapshot every 2 ticks and advances one real-time tick per tick. Returns how many times the
## remote's clip instant goes back (a restart) and how many times the local layer's does.
func _count_restarts(fighter: Combatant, last_rel: int, buttons_at: Callable,
		impose: Callable) -> Vector2i:
	var clips: CombatClipSet = _clips
	var remote := CombatAnimationLayer.new(clips)
	var local := CombatAnimationLayer.new(clips)
	var combat: CombatState = fighter.get_character().combat
	var dt: float = 1.0 / _tick_rate
	var snapshot_byte: int = ActionMachine.action_byte(combat, START_TICK)
	var previous_remote: float = -1.0
	var previous_local: float = -1.0
	var remote_restarts: int = 0
	var local_restarts: int = 0
	for rel: int in range(1, last_rel + 1):
		var input := PlayerInput.new()
		input.tick = START_TICK + rel
		input.move = Vector2(0.0, 1.0)
		input.buttons = int(buttons_at.call(rel))
		ActionMachine.step(combat, input, true)
		impose.call(rel, combat)
		fighter.publish(input.tick)
		if rel % 2 == 0:
			snapshot_byte = fighter.entity.action
		remote.update_remote(snapshot_byte, dt)
		local.update_local(combat, input.tick, 0.0, dt)
		var remote_time: float = remote.get_current().time_s if remote.get_current() != null else -1.0
		var local_time: float = local.get_current().time_s if local.get_current() != null else -1.0
		if previous_remote >= 0.0 and remote_time >= 0.0 and remote_time + 0.0001 < previous_remote:
			remote_restarts += 1
		if previous_local >= 0.0 and local_time >= 0.0 and local_time + 0.0001 < previous_local:
			local_restarts += 1
		previous_remote = remote_time
		previous_local = local_time
	return Vector2i(remote_restarts, local_restarts)


func test_a_remote_replays_a_second_dodge_chained_by_the_buffer() -> void:
	# T2: the second dodge comes out of the buffer on the tick the first one ends, with no tick in
	# NONE: the action byte would be the same and the remote would stay frozen on the last pose.
	var fighter: Combatant = _make_server_fighter(1)
	var restarts: Vector2i = _count_restarts(fighter, 70,
			func(rel: int) -> int: return DODGE if rel == 1 or rel == 22 else 0,
			func(_rel: int, _combat: CombatState) -> void: pass)
	assert_eq(restarts.y, 1, "the local layer restarts the clip when the second dodge starts")
	assert_eq(restarts.x, 1, "and the remote too, even though it sees no tick without a dodge")


func test_a_remote_replays_a_second_control_whatever_the_gap_between_them() -> void:
	# Two staggers (or stuns) in a row share a byte: the remote must restart the clip on
	# the second one whatever the separation between them.
	var first_tick: int = 10
	for gap: int in range(2, 12):
		var fighter: Combatant = _make_server_fighter(10 + gap)
		var restarts: Vector2i = _count_restarts(fighter, first_tick + gap + 10,
				func(_rel: int) -> int: return 0,
				func(rel: int, combat: CombatState) -> void:
					if rel == first_tick or rel == first_tick + gap:
						ActionMachine.impose_stagger(combat, START_TICK + rel, START_TICK + rel + 40,
								Vector2.ZERO))
		assert_eq(restarts.x, 1, "%d ticks apart: the remote restarts the stagger" % gap)
		assert_eq(restarts.y, 1, "(and the local one too)")
	var stun_fighter: Combatant = _make_server_fighter(99)
	var stun_restarts: Vector2i = _count_restarts(stun_fighter, 40,
			func(_rel: int) -> int: return 0,
			func(rel: int, combat: CombatState) -> void:
				if rel == 10 or rel == 17:
					ActionMachine.impose_stun(combat, START_TICK + rel, START_TICK + rel + 40))
	assert_eq(stun_restarts.x, 1, "two stuns in a row too")


func test_a_remote_does_not_restart_a_dodge_or_a_control_that_just_goes_on() -> void:
	var fighter: Combatant = _make_server_fighter(3)
	var restarts: Vector2i = _count_restarts(fighter, 40,
			func(rel: int) -> int: return DODGE if rel == 1 else 0,
			func(_rel: int, _combat: CombatState) -> void: pass)
	assert_eq(restarts, Vector2i(0, 0), "a single dodge does not restart halfway")
	var staggered: Combatant = _make_server_fighter(4)
	restarts = _count_restarts(staggered, 40,
			func(_rel: int) -> int: return 0,
			func(rel: int, combat: CombatState) -> void:
				if rel == 5:
					ActionMachine.impose_stagger(combat, START_TICK + rel, START_TICK + rel + 30,
							Vector2.ZERO))
	assert_eq(restarts, Vector2i(0, 0), "nor does a single stagger")


# --- Pose on the skeleton ---------------------------------------------------------------------

## Truly animated humanoid (capsule replaced) hung from a character.
func _make_visual() -> HumanoidVisual:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() \
			as PlayerCharacter
	world.add_child(character)
	var visual: HumanoidVisual = HumanoidVisual.install(character)
	return visual


func test_footsteps_do_not_depend_on_the_frame_rate() -> void:
	var counts: Array[int] = []
	for fps: int in [30, 60, 144, 240]:
		var visual: HumanoidVisual = _make_visual()
		if not assert_not_null(visual):
			return
		var dt: float = 1.0 / float(fps)
		var steps: int = 0
		var time: float = 0.0
		# A foot that lifts 0.2 m and lands at 1.25 steps per second (walking while drawing the bow), 6 s.
		while time < 6.0:
			var phase: float = fmod(time * 1.25, 1.0)
			var height: float = 0.1 + (0.2 * sin(phase / 0.4 * PI) if phase < 0.4 else 0.0)
			if visual._track_foot(0, height, dt):
				steps += 1
			time += dt
		counts.append(steps)
	assert_true(counts[0] >= 6, "steps are heard: %s" % [counts])
	for count: int in counts:
		assert_true(absi(count - counts[1]) <= 1, "the same steps at any FPS: %s" % [counts])


func test_the_death_slide_is_gone_when_the_character_respawns() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var character: PlayerCharacter = visual.get_animator().get_character()
	character.grounded = true
	character.velocity = Vector3(0.0, 0.0, -6.0)
	await wait_process_frames(40)
	character.velocity = Vector3.ZERO
	character.combat.action = CombatState.Action.DEAD
	await wait_process_frames(60)
	assert_true(visual.get_pivot().position.length() > 0.1, "the body slid while dying")
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(3)
	assert_near(visual.get_pivot().position.length(), 0.0, 0.001, "and it is back in the capsule on respawn")


func test_weapon_placeholders_hang_from_the_hands() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: BoneAttachment3D = skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT)) \
			as BoneAttachment3D
	var shield: BoneAttachment3D = skeleton.get_node_or_null(NodePath(WeaponProps.SHIELD_ATTACHMENT)) \
			as BoneAttachment3D
	if not assert_not_null(sword, "there is a sword") or not assert_not_null(shield, "and a shield"):
		return
	assert_eq(sword.bone_name, "RightHand", "the sword in the right hand")
	assert_eq(shield.bone_name, "LeftHand", "and the shield in the left")
	# The sword is now the own model (SwordModel), not the box: two LOD meshes and it is not provisional.
	var blade: MeshInstance3D = sword.find_child(String(SwordModel.LOD0_NAME), true, false) as MeshInstance3D
	if assert_not_null(blade, "the sword is the model with its full-detail mesh"):
		assert_true(blade.mesh is ArrayMesh and not (blade.mesh is BoxMesh), "a modeled mesh, not a box")
	assert_not_null(sword.find_child(String(SwordModel.LOD1_NAME), true, false), "and the simple-detail one")
	assert_null(sword.find_child("Hoja", true, false), "without the fallback box")
	var disc: MeshInstance3D = shield.find_child("Disco", true, false) as MeshInstance3D
	assert_true(disc.mesh is CylinderMesh, "and a flattened cylinder for the shield")
	var cylinder: CylinderMesh = disc.mesh as CylinderMesh
	assert_true(cylinder.height < cylinder.top_radius * 0.5, "flattened")
	assert_false(bool(sword.get_child(0).get_meta(&"placeholder", true)), "the sword is no longer provisional")
	assert_true(bool(shield.get_child(0).get_meta(&"placeholder", false)), "the shield is")
	var again: Array[BoneAttachment3D] = WeaponProps.install(skeleton)
	assert_null(again[0], "installing them again duplicates nothing")
	var count: int = 0
	for child: Node in skeleton.get_children():
		if child is BoneAttachment3D:
			count += 1
	assert_eq(count, 2)


func test_weapons_follow_the_hand_bone() -> void:
	var visual: HumanoidVisual = _make_visual()
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT)) \
			as BoneAttachment3D
	# The combat stance moves the hand after the tree sets its pose: here only the grip on the
	# bone is checked, so it is switched off to read the bone and the sword at the same instant.
	visual.get_animator().get_stance_modifier().active = false
	await wait_process_frames(3)
	var hand: int = skeleton.find_bone("RightHand")
	var hand_global: Transform3D = skeleton.global_transform * skeleton.get_bone_global_pose(hand)
	assert_vec_near(sword.global_position, hand_global.origin, 0.05,
			"the sword is in the hand (not at the origin)")
	assert_true(sword.global_position.distance_to(visual.global_position) > 0.2)


func test_pose_modifier_blends_upper_body_clips_into_the_upper_bones_only() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var modifier: CombatPoseModifier = animator.get_combat_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	assert_not_null(modifier, "the humanoid brings its combat modifier")
	assert_not_null(layer)
	await wait_process_frames(2)
	var chest: int = skeleton.find_bone("Chest")
	var left_leg: int = skeleton.find_bone("LeftUpperLeg")
	var before_chest: Quaternion = skeleton.get_bone_pose_rotation(chest)
	var before_leg: Quaternion = skeleton.get_bone_pose_rotation(left_leg)
	# Block (upper body) at full weight.
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
			ActionMachine.PHASE_NONE, 0, 1000.0)
	layer.apply_plan(plan, 1.0)
	var slot: CombatAnimationLayer.Slot = layer.get_current()
	assert_near(slot.weight, 1.0, 0.0001)
	modifier._process_modification()
	var clip: Animation = slot.animation
	var expected: Quaternion = Quaternion.IDENTITY
	var found: bool = false
	for track: int in clip.get_track_count():
		if String(clip.track_get_path(track)).ends_with(":Chest") \
				and clip.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			expected = clip.rotation_track_interpolate(track, slot.time_s)
			found = true
	assert_true(found, "the clip animates the chest")
	var after_chest: Quaternion = skeleton.get_bone_pose_rotation(chest)
	assert_true(after_chest.angle_to(expected) < 0.001, "the chest keeps the clip's pose")
	assert_true(after_chest.angle_to(before_chest) > 0.001, "and changes relative to locomotion")
	var after_leg: Quaternion = skeleton.get_bone_pose_rotation(left_leg)
	assert_true(after_leg.angle_to(before_leg) < 0.0001, "the legs stay with locomotion")
	assert_true(modifier.get_applied_count() >= 1)
	assert_true(modifier.get_upper_body_bones().size() > 20, "the upper-body mask (%d bones)" % modifier.get_upper_body_bones().size())
	assert_false(modifier.get_upper_body_bones().has(left_leg))


func test_pose_modifier_full_body_clip_moves_legs_and_hips_and_zero_weight_does_nothing() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var modifier: CombatPoseModifier = animator.get_combat_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	await wait_process_frames(2)
	var hips: int = skeleton.find_bone("Hips")
	var left_leg: int = skeleton.find_bone("LeftUpperLeg")
	var rest_leg: Quaternion = skeleton.get_bone_pose_rotation(left_leg)
	var rest_hips: Vector3 = skeleton.get_bone_pose_position(hips)
	# Without a plan nothing is touched.
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(left_leg).angle_to(rest_leg) < 0.0001, "without a clip, no changes")
	# Death (full body), at the end of the clip: the hips drop to the ground.
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DEAD,
			ActionMachine.PHASE_NONE, 0, 100000.0)
	layer.apply_plan(plan, 1.0)
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(left_leg).angle_to(rest_leg) > 0.01, "the leg follows the clip")
	assert_true(skeleton.get_bone_pose_position(hips).y < rest_hips.y - 0.3,
			"the hips drop (%.2f -> %.2f)" % [rest_hips.y, skeleton.get_bone_pose_position(hips).y])


func test_animator_follows_the_local_combat_state_and_a_remote_byte() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_physics_frames(2)
	# Local: it is given an attack state and the animator picks it up.
	var driver := Driver.new()
	driver.step()
	driver.step(PRIMARY)
	character.combat.copy_from(driver.c)
	character.last_input_tick = driver.tick
	await wait_process_frames(2)
	var local: Dictionary = animator.get_debug_state()["combat"]
	assert_true(bool(local["active"]), "the animator animates the attack")
	assert_eq(local["key"], &"sword_light_1")
	assert_true(bool(local["upper_body"]))
	# Remote: the action comes from the byte returned by the source.
	var holder: Array[int] = [_byte(CombatState.Action.BLOCK, ActionMachine.PHASE_NONE)]
	character.combat.copy_from(CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id()))
	animator.set_remote_source(func() -> int: return holder[0])
	await wait_process_frames(3)
	var remote: Dictionary = animator.get_debug_state()["combat"]
	assert_eq(remote.get("key"), &"block", "the remote blocks according to its byte")
	holder[0] = 0x30
	await wait_physics_frames(45)
	var idle: Dictionary = animator.get_debug_state()["combat"]
	assert_false(bool(idle.get("active", true)), "without an action, the layer empties")


func test_remote_world_wires_the_animator_to_the_drawn_action() -> void:
	var clock := RemoteWorldClock.new()
	var world := RemoteWorld.new()
	world.install_visuals = true
	world.setup(clock)
	tree.root.add_child(world)
	_nodes.append(world)
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 9
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 1
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.display_name = "Ana"
	var state := PlayerState.new()
	state.grounded = true
	spawn.state = state
	world.on_spawn(spawn)
	var view: RemotePlayerView = world.get_view(9)
	var visual: HumanoidVisual = view.get_body().get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if not assert_not_null(visual, "the remote carries the humanoid"):
		return
	for tick: int in [2, 4]:
		var record := EntityRecord.new()
		record.net_id = 9
		record.flags = EntityRecord.FLAG_GROUNDED
		record.action = _byte(CombatState.Action.DODGE, ActionMachine.PHASE_NONE)
		var snapshot := NetMessages.Snapshot.new()
		snapshot.server_tick = tick
		snapshot.records = [record] as Array[EntityRecord]
		world.on_snapshot(snapshot)
	clock.render = 3.0
	world.draw(3.0, 0.016)
	await wait_process_frames(3)
	var combat: Dictionary = visual.get_animator().get_debug_state()["combat"]
	assert_eq(combat.get("key"), &"dodge", "the remote's animator reads the action byte of its record")


## Draw clock set from the test.
class RemoteWorldClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


# --- Phase 4: abilities, bow, knockdown (provisional, docs/abilities.md, section 6.6) ----------

const BOW_CLIPS_PATH: String = "res://data/animation/bow_clips.tres"


func test_each_weapon_has_its_clip_set_with_the_phase_4_entries() -> void:
	var bow_clips: CombatClipSet = load(BOW_CLIPS_PATH) as CombatClipSet
	if not assert_not_null(bow_clips, "the bow has its clip set"):
		return
	var sword_id: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow_id: int = CombatCatalog.weapon_id(&"bow")
	assert_eq(CombatAnimationLayer.clips_for(bow_id, _clips), bow_clips, "that of its weapon")
	assert_eq(CombatAnimationLayer.clips_for(sword_id, null).resource_path, CLIPS_PATH)
	var npc: int = CombatCatalog.weapon_id(&"npc_guard")
	var npc_clips: CombatClipSet = CombatAnimationLayer.clips_for(npc, _clips)
	assert_true(npc_clips != _clips and npc_clips.resource_path.ends_with("npc_guard_clips.tres"),
			"an NPC uses its own set (ART-47)")
	assert_eq(CombatAnimationLayer.clips_for(0, _clips), _clips, "an unknown weapon uses the default one")
	var common: Array[StringName] = [&"drink", &"swap", &"downed", &"downed_crawl", &"revive", &"execute",
			&"get_up", &"dodge", &"stagger", &"stun", &"dead"]
	for key: StringName in common + ([&"shield_bash", &"shield_rush", &"shield_wall", &"block", &"charge"]
			as Array[StringName]):
		assert_not_null(_clips.find(key), "sword and shield: %s" % key)
	for key: StringName in common + ([&"bow_quick", &"bow_drawn", &"bow_volley", &"bow_slowing_shot",
			&"bow_evasive_shot", &"charge"] as Array[StringName]):
		assert_not_null(bow_clips.find(key), "bow: %s" % key)
	assert_null(bow_clips.find(&"block"), "the bow does not block")
	assert_true(_clips.find(&"downed_crawl").loop, "crawling repeats")
	assert_true(_clips.find(&"downed").loop, "knocked down and still, on the knees and looping (ART-51)")
	# All the bow's segments exist and fit in their clip (the sword's are already checked by another test).
	for entry: CombatActionAnim in bow_clips.entries:
		for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
			if segment == null:
				continue
			var animation: Animation = bow_clips.get_animation(segment.animation)
			if not assert_not_null(animation, "%s: the clip %s exists" % [entry.key, segment.animation]):
				continue
			assert_true(segment.from_s >= 0.0 and segment.to_s <= animation.length + 0.0001
					and segment.to_s > segment.from_s, "%s: the segment fits in %s" % [entry.key, segment.animation])
	for name_of_attack: StringName in [&"bow_quick", &"bow_drawn"]:
		var attack: AttackTicks = _attack(name_of_attack)
		var contact: float = CombatClipPlanner.contact_tick(bow_clips.find(name_of_attack), attack)
		assert_true(contact >= float(attack.active_from()) - 1.0 and contact <= float(attack.active_to()) + 1.0,
				"%s: the shot falls on its active tick (%.1f)" % [name_of_attack, contact])


func test_the_planner_animates_abilities_potions_swap_and_downed() -> void:
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var potion: int = CombatCatalog.consumable_ids()[1]
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.ABILITY, 0, bash.id), &"shield_bash",
			"an ability, by its name")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.ABILITY, 0, potion), &"drink",
			"a potion, drinking")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.SWAP, 0), &"swap")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.DOWNED, 0), &"downed")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.DOWNED, 0, 0, true), &"downed_crawl",
			"knocked down and moving, it crawls")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.REVIVE, 0), &"revive")
	assert_eq(CombatClipPlanner.key_for(_weapon, CombatState.Action.EXECUTE, 0), &"execute")
	assert_eq(CombatClipPlanner.ability_of_slot(_weapon, 0), bash.id, "slot 1 of a remote's byte")
	assert_eq(CombatClipPlanner.ability_of_slot(_weapon, 3), CombatCatalog.consumable_ids()[0],
			"slot 3 is drinking")
	# Each phase of the ability is stretched to its own: cast, active and recovery.
	var entry: CombatActionAnim = _clips.find(&"shield_bash")
	var lengths: Array[int] = [bash.cast_ticks, bash.active_ticks, bash.recovery_ticks]
	for phase: int in 3:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.ABILITY,
				phase, 0, 0.0, 0, bash.id)
		assert_eq(plan.animation, entry.segment_for_phase(phase).animation)
		assert_near(plan.duration_s, float(lengths[phase]) / _tick_rate, 0.0001,
				"phase %d of the shield bash, in its duration" % phase)
	var swap: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.SWAP,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_near(swap.duration_s, float(CombatCatalog.tables().swap_ticks) / _tick_rate, 0.0001,
			"the weapon swap lasts its 0.4 s")
	var revive: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.REVIVE,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_eq(revive.animation, &"ual1/Fixing_Kneeling")
	assert_near(revive.duration_s, float(CombatCatalog.tables().revive_ticks) / _tick_rate, 0.0001)
	# Crawling repeats: past its duration it goes back to the start.
	var crawl: CombatActionAnim = _clips.find(&"downed_crawl")
	var crawl_ticks: float = crawl.duration_s * _tick_rate
	var later: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DOWNED,
			ActionMachine.PHASE_NONE, 0, crawl_ticks * 1.25, 0, 0, true)
	assert_near(later.time_s, lerpf(crawl.windup.from_s, crawl.windup.to_s, 0.25), 0.0001)


func test_the_layer_uses_the_weapons_clips_the_remote_ability_and_gets_up_after_being_revived() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var dt: float = 1.0 / _tick_rate
	var bow: int = CombatCatalog.weapon_id(&"bow")
	# Local with the bow: the quick shot comes from its set.
	var state := CombatState.initial(CombatCatalog.rules(), bow)
	state.action = CombatState.Action.LIGHT
	state.action_id = CombatCatalog.attack_id(&"bow_quick")
	state.action_tick = START_TICK
	layer.update_local(state, START_TICK + 1, 0.0, dt)
	assert_eq(layer.get_current().key, &"bow_quick")
	assert_eq(layer.get_current().animation_name, &"ual1/Pistol_Aim_Neutral")
	# A remote with the sword and shield in slot 2 of its byte: the charge.
	var remote := CombatAnimationLayer.new(_clips)
	remote.update_remote(_byte(CombatState.Action.ABILITY, ActionMachine.PHASE_ACTIVE, 1), dt,
			CombatCatalog.weapon_id(&"sword_shield"))
	assert_eq(remote.get_current().key, &"shield_rush", "the ability of the byte's slot")
	assert_false(remote.get_current().upper_body, "full-body")
	remote.update_remote(_byte(CombatState.Action.ABILITY, ActionMachine.PHASE_WINDUP, 3), dt)
	assert_eq(remote.get_current().key, &"drink", "slot 3 is drinking")
	# Knocked down, picked up and standing: it gets up once.
	for _i: int in 10:
		remote.update_remote(_byte(CombatState.Action.DOWNED, ActionMachine.PHASE_NONE), dt, 0, true)
	assert_eq(remote.get_current().key, &"downed_crawl")
	remote.update_remote(_byte(CombatState.Action.NONE, ActionMachine.PHASE_NONE), dt)
	assert_eq(remote.get_current().key, &"get_up", "they have lifted him: he gets up")
	for _i: int in roundi(_clips.find(&"get_up").duration_s * _tick_rate) + 2:
		remote.update_remote(_byte(CombatState.Action.NONE, ActionMachine.PHASE_NONE), dt)
	assert_eq(remote.get_plan(), null, "and then, nothing")
	remote.update_remote(0x0E, dt)
	assert_null(remote.get_plan(), "action 14 (free) is not animated")


func test_the_props_follow_the_weapon_in_the_hands() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var skeleton: Skeleton3D = visual.get_skeleton()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	var sword: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT)) as BoneAttachment3D
	var left: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SHIELD_ATTACHMENT)) as BoneAttachment3D
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), character.combat.weapon_id)
	assert_true(sword.visible, "with the sword and shield, the sword")
	assert_null(left.get_node_or_null(NodePath(WeaponProps.BOW_MESH)), "the bow does not exist yet")
	# Switches to the bow (the predicted state): the bow is shown and neither the sword nor the shield.
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), CombatCatalog.weapon_id(&"bow"))
	assert_false(sword.visible, "no sword")
	var bow_node: Node3D = left.get_node_or_null(NodePath(WeaponProps.BOW_MESH)) as Node3D
	if not assert_not_null(bow_node, "the provisional bow in the left hand"):
		return
	assert_true(bow_node.visible)
	assert_false((left.get_node(NodePath(WeaponProps.SHIELD_MESH)) as Node3D).visible, "no shield")
	assert_true(bool(bow_node.get_meta(&"placeholder", false)), "marked as provisional")
	# A remote: the weapon comes from its view (pair and slot bit).
	var holder: Array[int] = [CombatCatalog.weapon_id(&"sword_shield")]
	animator.set_remote_source(func() -> int: return 0x30, func() -> int: return holder[0])
	await wait_process_frames(2)
	assert_true(sword.visible, "the remote carries the sword")
	assert_false(bow_node.visible)
