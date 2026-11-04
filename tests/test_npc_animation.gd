extends TestCase
## Clip coverage for all the weapons in the combat catalog and animation of the NPCs (ART-47).
## [br]- Every attack (light and heavy) of every weapon in [code]data/combat[/code] has an entry in
## its [CombatClipSet], and NPC weapons also cover charging, blocking, dodging, staggering, being
## stunned and dying: no NPC action is left without a clip and slides in place.
## [br]- The NPC segments exist in UAL, fit in their clip and play at a reasonable speed (the
## anticipation ones slower than the original on purpose: the blow can be seen coming).
## [br]- The contact of each attack falls within its active window, and an NPC's layer (local or
## remote) shows the clip of its attack in each phase.

## Playback speed (seconds of clip per real second) allowed in each phase of an NPC attack. The
## anticipation and recovery of an NPC last longer than the segments the UAL clips offer (they are
## made so the blow can be seen coming), so they go below the 0.7x floor; the active blow does not.
const WINDUP_SPEED: Vector2 = Vector2(0.3, 1.5)
const ACTIVE_SPEED: Vector2 = Vector2(0.7, 1.5)
const RECOVERY_SPEED: Vector2 = Vector2(0.4, 1.5)
## Entries of non-attack actions that every NPC needs.
const NPC_ACTION_KEYS: Array[StringName] = [&"charge", &"block", &"dodge", &"stagger", &"stun", &"dead"]

var _tick_rate: float = 60.0


func before_each() -> void:
	_tick_rate = float(Engine.physics_ticks_per_second)


## The ids of all the weapons in the catalog (1..n).
func _weapon_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	var id: int = 1
	while CombatCatalog.weapon(id) != null:
		ids.append(id)
		id += 1
	return ids


func _is_npc(weapon: WeaponTicks) -> bool:
	return String(weapon.name).begins_with(CombatCatalog.NPC_PREFIX)


# --- Coverage ---------------------------------------------------------------------------------

func test_every_attack_of_every_weapon_has_a_clip_entry() -> void:
	var ids: PackedInt32Array = _weapon_ids()
	assert_true(ids.size() >= 6, "there are weapons in the catalog (%d)" % ids.size())
	for weapon_id: int in ids:
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		var clips: CombatClipSet = CombatAnimationLayer.clips_for(weapon_id, null)
		if not assert_not_null(clips, "%s has its own set of clips in data/animation" % weapon.name):
			continue
		var attack_ids: Array[int] = []
		for light_id: int in weapon.light_ids:
			attack_ids.append(light_id)
		attack_ids.append(weapon.heavy_id)
		for attack_id: int in attack_ids:
			var attack: AttackTicks = CombatCatalog.attack(attack_id)
			if not assert_not_null(attack, "%s: attack %d exists" % [weapon.name, attack_id]):
				continue
			var entry: CombatActionAnim = clips.find(attack.name)
			if assert_not_null(entry, "%s: attack %s has a clip" % [weapon.name, attack.name]):
				assert_true(entry.is_attack(), "%s: %s has the three segments" % [weapon.name, attack.name])
		for slot: int in CombatState.ABILITY_SLOTS:
			var ability: AbilityTicks = CombatCatalog.ability(weapon.ability_id(slot))
			if ability != null:
				assert_not_null(clips.find(ability.name), "%s: ability %s has a clip" % [weapon.name, ability.name])
		if _is_npc(weapon):
			for key: StringName in NPC_ACTION_KEYS:
				assert_not_null(clips.find(key), "%s: action %s has a clip" % [weapon.name, key])


func test_the_planner_returns_a_clip_for_every_action_an_npc_performs() -> void:
	var covered: int = 0
	for weapon_id: int in _weapon_ids():
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		if not _is_npc(weapon):
			continue
		var clips: CombatClipSet = CombatAnimationLayer.clips_for(weapon_id, null)
		if clips == null:
			continue
		var actions: Array[int] = [CombatState.Action.LIGHT, CombatState.Action.HEAVY,
				CombatState.Action.CHARGE, CombatState.Action.BLOCK, CombatState.Action.DODGE,
				CombatState.Action.STAGGER, CombatState.Action.STUN, CombatState.Action.DEAD]
		for action: int in actions:
			var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(clips, weapon, action,
					ActionMachine.PHASE_WINDUP, 0, 0.0)
			assert_not_null(plan, "%s: action %d has an animation" % [weapon.name, action])
			if plan != null:
				assert_not_null(clips.get_animation(plan.animation), "%s: clip %s exists" % [weapon.name, plan.animation])
				covered += 1
	assert_eq(covered, 4 * 8, "the four NPCs and their eight actions")


# --- The segments -----------------------------------------------------------------------------

func test_every_npc_segment_points_into_an_existing_clip() -> void:
	var checked: int = 0
	for weapon_id: int in _weapon_ids():
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		if not _is_npc(weapon):
			continue
		var clips: CombatClipSet = CombatAnimationLayer.clips_for(weapon_id, null)
		if clips == null:
			continue
		for entry: CombatActionAnim in clips.entries:
			for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
				if segment == null:
					continue
				var animation: Animation = clips.get_animation(segment.animation)
				if not assert_not_null(animation, "%s/%s: clip %s exists" % [weapon.name, entry.key, segment.animation]):
					continue
				checked += 1
				assert_true(segment.from_s >= 0.0 and segment.to_s <= animation.length + 0.0001 \
						and segment.to_s > segment.from_s,
						"%s/%s: [%.3f, %.3f] fits in %s (%.3f s)" % [weapon.name, entry.key, segment.from_s,
						segment.to_s, segment.animation, animation.length])
	assert_true(checked >= 40, "%d segments were checked" % checked)


func test_npc_attack_phases_play_at_a_sensible_speed() -> void:
	var bounds: Array[Vector2] = [WINDUP_SPEED, ACTIVE_SPEED, RECOVERY_SPEED]
	var names: Array[String] = ["anticipación", "golpe", "recuperación"]
	for weapon_id: int in _weapon_ids():
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		if not _is_npc(weapon):
			continue
		var clips: CombatClipSet = CombatAnimationLayer.clips_for(weapon_id, null)
		if clips == null:
			continue
		var attack_ids: Array[int] = [weapon.light_ids[0], weapon.heavy_id]
		for attack_id: int in attack_ids:
			var attack: AttackTicks = CombatCatalog.attack(attack_id)
			var entry: CombatActionAnim = clips.find(attack.name)
			if entry == null or not entry.is_attack():
				continue
			var action: int = CombatState.Action.HEAVY if attack.heavy else CombatState.Action.LIGHT
			for phase: int in 3:
				var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(clips, weapon, action, phase, 0, 0.0)
				if not assert_not_null(plan, "%s: there is a plan in phase %d" % [attack.name, phase]):
					continue
				assert_true(plan.speed >= bounds[phase].x and plan.speed <= bounds[phase].y,
						"%s, %s at %.2fx (allowed %.1fx to %.1fx)" % [attack.name, names[phase], plan.speed,
						bounds[phase].x, bounds[phase].y])


func test_npc_contact_falls_inside_the_active_window() -> void:
	for weapon_id: int in _weapon_ids():
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		if not _is_npc(weapon):
			continue
		var clips: CombatClipSet = CombatAnimationLayer.clips_for(weapon_id, null)
		if clips == null:
			continue
		for attack_id: int in [weapon.light_ids[0], weapon.heavy_id]:
			var attack: AttackTicks = CombatCatalog.attack(attack_id)
			var contact: float = CombatClipPlanner.contact_tick(clips.find(attack.name), attack)
			assert_true(contact >= float(attack.active_from()) - 1.0 and contact <= float(attack.active_to()) + 1.0,
					"%s: the contact falls within its active window (tick %.1f from %d to %d)" % [attack.name, contact,
					attack.active_from(), attack.active_to()])


func test_the_heavy_charge_continues_into_the_windup_without_a_jump() -> void:
	# With the same clip, the charge stays in the pose the heavy attack's anticipation starts with: there is no jump
	# on release.
	for weapon_id: int in _weapon_ids():
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		if not _is_npc(weapon):
			continue
		var clips: CombatClipSet = CombatAnimationLayer.clips_for(weapon_id, null)
		if clips == null:
			continue
		var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
		var charge: CombatActionAnim = clips.find(&"charge")
		var entry: CombatActionAnim = clips.find(heavy.name)
		if charge == null or entry == null:
			continue
		assert_true(charge.hold_end, "%s: the charge holds its last pose" % weapon.name)
		assert_eq(charge.upper_body, entry.upper_body, "%s: charge and blow, with the same body parts" % weapon.name)
		if charge.windup.animation != entry.windup.animation:
			# Another clip (the shield guard before the guard's shove): the starting pose is the same.
			continue
		assert_near(charge.windup.to_s, entry.windup.from_s, 0.0001,
				"%s: the charge ends where the anticipation starts" % weapon.name)


# --- An NPC's layer ---------------------------------------------------------------------------

func test_a_remote_npc_shows_its_attack_clip_in_every_phase() -> void:
	var dt: float = 1.0 / _tick_rate
	var fallback: CombatClipSet = load("res://data/animation/sword_shield_clips.tres") as CombatClipSet
	var expected: Dictionary = {
		&"npc_hollow": [&"npc_hollow_swipe", &"ual2/Zombie_Scratch"],
		&"npc_captain": [&"npc_captain_sweep", &"ual1/Sword_Attack"],
		&"npc_guard": [&"npc_guard_slash", &"ual1/Sword_Attack"],
		&"npc_guardian": [&"npc_guardian_halberd", &"ual1/Sword_Attack"],
	}
	for npc_name: StringName in expected:
		var weapon_id: int = CombatCatalog.weapon_id(npc_name)
		for phase: int in 3:
			var layer := CombatAnimationLayer.new(fallback)
			layer.update_remote(CombatState.Action.LIGHT | (phase << 4), dt, weapon_id)
			var slot: CombatAnimationLayer.Slot = layer.get_current()
			if not assert_not_null(slot, "%s phase %d: there is a clip" % [npc_name, phase]):
				continue
			assert_eq(slot.key, (expected[npc_name] as Array)[0], "%s: the key of its attack" % npc_name)
			assert_eq(slot.animation_name, (expected[npc_name] as Array)[1], "%s: its clip, not the hero's" % npc_name)
			assert_not_null(slot.animation, "%s: the clip resolves" % npc_name)
		# Without an action there is no clip, and with a heavy attack's charge its own comes out.
		var charging := CombatAnimationLayer.new(fallback)
		charging.update_remote(CombatState.Action.CHARGE, dt, weapon_id)
		assert_eq(charging.get_current().key, &"charge", "%s: charge" % npc_name)


func test_a_local_npc_state_plays_the_npc_clip_with_its_ticks() -> void:
	var fallback: CombatClipSet = load("res://data/animation/sword_shield_clips.tres") as CombatClipSet
	var weapon_id: int = CombatCatalog.weapon_id(&"npc_captain")
	var crush: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"npc_captain_crush"))
	var layer := CombatAnimationLayer.new(fallback)
	var state := CombatState.initial(CombatCatalog.rules(), weapon_id)
	state.action = CombatState.Action.HEAVY
	state.action_id = crush.id
	state.action_tick = 1000
	var start: int = 1000
	var middle_of_windup: int = start + crush.windup_ticks / 2
	layer.update_local(state, middle_of_windup, 0.0, 1.0 / _tick_rate)
	var slot: CombatAnimationLayer.Slot = layer.get_current()
	if not assert_not_null(slot, "the Captain's crush has a clip"):
		return
	assert_eq(slot.key, &"npc_captain_crush")
	assert_eq(slot.animation_name, &"ual2/Sword_Heavy_Combo")
	var entry: CombatActionAnim = CombatAnimationLayer.clips_for(weapon_id, null).find(&"npc_captain_crush")
	assert_near(slot.time_s, (entry.windup.from_s + entry.windup.to_s) * 0.5, 0.01, "halfway through the anticipation, halfway through the segment")
	assert_false(slot.upper_body, "the NPC attacks with its whole body: it crouches and throws itself forward")
