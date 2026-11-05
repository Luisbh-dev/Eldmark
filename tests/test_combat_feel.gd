extends TestCase
## Tests of the hit feel (quality wave 4: ART-09, ART-11, UI-12): the impact of every confirmed hit,
## the locally predicted hit, hitstop (animation only), the heavy attack's trail, the effects
## ([CombatVfx]) and the legibility of the numbers and the marker.

const OWN_ID: int = 5
const OTHER_ID: int = 21
const THIRD_ID: int = 22
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

var _root: Node3D
var _feedback: CombatFeedback
var _character: PlayerCharacter
var _impacts: Array = []


func before_each() -> void:
	_impacts.clear()
	_root = Node3D.new()
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	_feedback = null
	_character = null
	await wait_process_frames()


func _make_feedback() -> void:
	_character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_root.add_child(_character)
	_feedback = CombatFeedback.new()
	_root.add_child(_feedback)
	_feedback.setup(null, null, _character, null, null)
	_feedback.set_own_net_id(OWN_ID)
	_feedback.position_resolver = func(net_id: int) -> Vector3:
		return Vector3(0.0, 0.0, -3.0) if net_id == OTHER_ID else Vector3(4.0, 0.0, -3.0)
	_feedback.hit_impact.connect(func(event: NetMessages.EntityEvent, position: Vector3, involves_me: bool,
			already: bool) -> void:
		_impacts.append({"event": event, "position": position, "mine": involves_me, "already": already}))


func _hit(victim: int, attacker: int, amount: int = 90, flags: int = 0, attack_id: int = 0,
		tick: int = 100) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.hit(victim, tick, attacker, amount, 0, flags, attack_id)


# --- Impact of every confirmed hit --------------------------------------------------------

func test_every_confirmed_hit_emits_an_impact_even_between_third_parties() -> void:
	_make_feedback()
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 90), false)
	assert_eq(_impacts.size(), 1, "a third party's hit also produces an impact (sound and spark)")
	assert_false(_impacts[0]["mine"], "the local player is not involved")
	_feedback.handle_event(_hit(THIRD_ID, OWN_ID, 90), true)
	assert_true(_impacts[1]["mine"], "an own one does")
	assert_vec_near(_impacts[0]["position"], Vector3(0.0, 0.0, -3.0), 0.001, "at the victim's feet")


func test_blocked_and_parried_hits_without_damage_still_emit_an_impact() -> void:
	_make_feedback()
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED), true)
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED), true)
	assert_eq(_impacts.size(), 2, "the block and the parry sound and throw sparks even if they take no health")


func test_a_confirmed_hit_after_the_local_prediction_does_not_repeat_the_effects() -> void:
	_make_feedback()
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	_feedback._predicted_attack = light
	_feedback._predicted_msec = Time.get_ticks_msec()
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, light), true)
	assert_true(_impacts[0]["already"], "the normal hit was already shown when it was predicted")
	_feedback._predicted_attack = light
	_feedback._predicted_msec = Time.get_ticks_msec()
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED, light), true)
	assert_false(_impacts[1]["already"], "if it turns out blocked, the block spark does come out")
	_feedback._predicted_attack = light
	_feedback._predicted_msec = Time.get_ticks_msec() - 5000
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, light), true)
	assert_false(_impacts[2]["already"], "an old prediction is not valid")


func test_parry_has_its_own_marker_kind() -> void:
	_make_feedback()
	var parry: NetMessages.EntityEvent = _hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED)
	assert_eq(_feedback.kind_of(parry), HitMarker.Kind.PARRY)
	assert_ne_kind(HitMarker.Kind.PARRY, HitMarker.Kind.BLOCKED)


func assert_ne_kind(a: int, b: int) -> void:
	assert_true(a != b, "variants %d and %d are different" % [a, b])


# --- Hitstop (animation only) ------------------------------------------------------

func _plan(time_s: float) -> CombatClipPlanner.Plan:
	var plan := CombatClipPlanner.Plan.new()
	plan.key = &"sword_light_1"
	plan.animation = &"x/y"
	plan.time_s = time_s
	plan.speed = 1.0
	return plan


func test_hitstop_freezes_the_clip_and_recovers_by_the_end_of_the_recovery() -> void:
	var layer := CombatAnimationLayer.new()
	var delta: float = 1.0 / 60.0
	var elapsed: float = 0.0
	layer.apply_plan(_plan(elapsed), delta)
	layer.start_hitstop(0.05)
	assert_true(layer.is_in_hitstop())
	var frozen_time: float = layer.get_current().time_s
	for frame: int in 3:
		elapsed += delta
		layer.apply_plan(_plan(elapsed), delta)
	assert_near(layer.get_current().time_s, frozen_time, 0.001, "during the hitstop the clip does not advance")
	for frame: int in 6:
		elapsed += delta
		layer.apply_plan(_plan(elapsed), delta)
	assert_false(layer.is_in_hitstop(), "50 ms later the hitstop has ended")
	assert_true(layer.get_hitstop_lag() > 0.0, "there is lag left to recover")
	assert_true(layer.get_current().time_s < elapsed, "the clip is behind the simulation")
	for frame: int in 40:
		elapsed += delta
		layer.apply_plan(_plan(elapsed), delta)
	assert_near(layer.get_hitstop_lag(), 0.0, 0.0001, "the lag is recovered by speeding up the clip")
	assert_near(layer.get_current().time_s, elapsed, 0.0001, "and goes back to the simulation's instant")


func test_hitstop_needs_a_clip_and_a_new_clip_cancels_it() -> void:
	var layer := CombatAnimationLayer.new()
	layer.start_hitstop(0.08)
	assert_false(layer.is_in_hitstop(), "without a clip there is nothing to freeze")
	layer.apply_plan(_plan(0.0), 1.0 / 60.0)
	layer.start_hitstop(0.08)
	var other := _plan(0.0)
	other.key = &"sword_heavy"
	layer.apply_plan(other, 1.0 / 60.0)
	assert_false(layer.is_in_hitstop(), "changing clips cancels the hitstop")
	assert_eq(layer.get_hitstop_lag(), 0.0)


func test_hitstop_durations_are_between_50_and_80_ms_for_blows() -> void:
	assert_near(CombatFeedback.HITSTOP_LIGHT, 0.05, 0.0001)
	assert_near(CombatFeedback.HITSTOP_HEAVY, 0.08, 0.0001)
	assert_true(CombatFeedback.HITSTOP_PARRY >= 0.08 and CombatFeedback.HITSTOP_PARRY <= 0.12, "the hitstop, ~100 ms")


# --- Heavy attack trail -------------------------------------------------------------------

func test_heavy_trail_is_more_opaque_wider_and_more_saturated_than_the_light_one() -> void:
	var light := SwordTrail.new()
	light.set_tint(SwordTrail.color_for(&"askarra"))
	light.set_active(true, false)
	var heavy := SwordTrail.new()
	heavy.set_tint(SwordTrail.color_for(&"askarra"))
	heavy.set_active(true, true)
	assert_true(heavy.get_peak_alpha() > light.get_peak_alpha() * 1.5, "more opaque")
	assert_true(heavy.is_heavy() and not light.is_heavy())
	var base := SwordTrail.new()
	base.set_tint(SwordTrail.color_for(&"base"))
	base.set_active(true, true)
	assert_true(base.get_body_color().s > SwordTrail.color_for(&"base").s, "the base's heavy does not come out pale")
	light.free()
	heavy.free()
	base.free()


func test_base_trail_is_not_the_blue_of_vardheim() -> void:
	var base: Color = SwordTrail.color_for(&"base")
	var vardheim: Color = SwordTrail.color_for(&"vardheim")
	assert_true(base.b <= base.r + 0.05, "the base sword's trail is not blue")
	assert_true(absf(base.h - vardheim.h) > 0.15 or base.s < 0.35, "nor does it look like Vardheim's ice blue")


# --- Effects -------------------------------------------------------------------------------------

func test_vfx_picks_the_effect_by_what_was_hit() -> void:
	var vfx := CombatVfx.new()
	_root.add_child(vfx)
	var victim: Vector3 = Vector3(0.0, 0.0, -3.0)
	var attacker: Vector3 = Vector3.ZERO
	vfx.spawn_impact(victim, attacker, CombatSoundBank.Armor.FLESH, false, false, false)
	assert_eq(vfx.get_spawn_count(&"flesh"), 1, "flesh bleeds")
	vfx.spawn_impact(victim, attacker, CombatSoundBank.Armor.MAIL, false, false, false)
	assert_eq(vfx.get_spawn_count(&"metal"), 1, "mail throws sparks")
	vfx.spawn_impact(victim, attacker, CombatSoundBank.Armor.GAMBESON, false, false, false)
	assert_eq(vfx.get_spawn_count(&"cloth"), 1, "the gambeson sheds cloth")
	vfx.spawn_impact(victim, attacker, CombatSoundBank.Armor.FLESH, true, false, false)
	assert_eq(vfx.get_spawn_count(&"block"), 1, "the block is splinters on the shield")
	assert_eq(vfx.get_spawn_count(&"flesh"), 1, "and there is no blood")
	vfx.spawn_impact(victim, attacker, CombatSoundBank.Armor.FLESH, false, true, false)
	assert_eq(vfx.get_spawn_count(&"parry"), 1, "the parry is the flash")
	assert_eq(vfx.get_spawn_count(&"metal"), 2, "with steel sparks")
	vfx.free()


func test_contact_point_is_the_chest_pulled_toward_the_attacker() -> void:
	var point: Vector3 = CombatVfx.contact_point(Vector3(0.0, 0.0, -3.0), Vector3.ZERO)
	assert_near(point.y, CombatVfx.CHEST_HEIGHT, 0.001, "at chest height")
	assert_near(point.z, -3.0 + CombatVfx.CHEST_FORWARD, 0.001, "shifted toward whoever strikes")


func test_vfx_abilities_each_have_an_effect() -> void:
	var vfx := CombatVfx.new()
	_root.add_child(vfx)
	vfx.play_ability(&"shield_bash", Vector3.ZERO, Vector3.FORWARD, 1)
	assert_eq(vfx.get_spawn_count(&"block"), 1, "the shield bash")
	assert_true(vfx.get_spawn_count(&"dust") >= 1, "and kicks up dust")
	vfx.play_ability(&"shield_rush", Vector3.ZERO, Vector3.FORWARD, 1)
	assert_true(vfx.get_spawn_count(&"dust") >= 2, "the charge leaves dust")
	vfx.play_ability(&"shield_wall", Vector3.ZERO, Vector3.FORWARD, 3)
	assert_eq(vfx.get_spawn_count(&"wall"), 1, "the wall has its arc")
	vfx.free()


func test_shield_wall_scene_is_a_vfx_effect_with_a_tintable_arc() -> void:
	var scene: PackedScene = load("res://scenes/vfx/shield_wall.tscn") as PackedScene
	assert_not_null(scene)
	var effect: VfxEffect = scene.instantiate() as VfxEffect
	assert_not_null(effect)
	assert_not_null(effect.get_node_or_null(^"Arch"), "has the arc")
	effect.free()


func test_death_dust_waits_for_the_body_to_reach_the_floor() -> void:
	var vfx := CombatVfx.new()
	_root.add_child(vfx)
	vfx.play_death_dust(Vector3.ZERO)
	assert_eq(vfx.get_spawn_count(&"dust"), 0, "it does not come out at the instant of the hit")
	await tree.create_timer(CombatVfx.DEATH_DUST_DELAY + 0.1).timeout
	assert_eq(vfx.get_spawn_count(&"dust"), 1, "it comes out when the body falls")
	vfx.free()


# --- Legible numbers and marker (UI-12) ----------------------------------------------------------

func test_numbers_of_the_same_target_do_not_overlap_when_they_are_born() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 225)
	numbers.advance(DamageNumbers.GROUP_WINDOW_SECONDS + 0.05)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 250)
	assert_eq(numbers.get_active_count(), 2, "outside the grouping window they are two numbers")
	var first: Vector2 = numbers.get_number_offset(0)
	var second: Vector2 = numbers.get_number_offset(1)
	assert_true(signf(first.x) != signf(second.x), "they are born on different sides")
	assert_true(second.y < first.y, "and the second one a step higher")
	numbers.free()


func test_numbers_of_different_targets_close_together_do_not_overlap() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	numbers.add_number(OTHER_ID + 1, Vector3(0.5, 0.0, 0.0), 135)
	assert_eq(numbers.get_active_count(), 2)
	assert_true(numbers.get_number_offset(1).y < numbers.get_number_offset(0).y,
			"the second victim's number is born a step higher")
	numbers.free()


func test_critical_has_its_own_color_and_size_and_kill_and_taken_are_not_confused() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	var normal: Label = numbers.add_number(1, Vector3.ZERO, 100, DamageNumbers.Kind.HIT, false, false)
	var crit: Label = numbers.add_number(2, Vector3.ZERO, 100, DamageNumbers.Kind.HIT, false, true)
	var normal_size: int = normal.get_theme_font_size(&"font_size")
	assert_true(crit.get_theme_font_size(&"font_size") >= normal_size + 4, "the critical is bigger")
	assert_eq(crit.get_theme_color(&"font_color"), DamageNumbers.CRITICAL_COLOR, "and of another color")
	assert_true(crit.text.ends_with("!"))
	var kill: Label = numbers.add_number(3, Vector3.ZERO, 100, DamageNumbers.Kind.KILL)
	var taken: Label = numbers.add_number(4, Vector3.ZERO, 100, DamageNumbers.Kind.HIT, true)
	assert_true(kill.get_theme_color(&"font_color") != taken.get_theme_color(&"font_color"),
			"death and damage received are not confused")
	assert_true(DamageNumbers.TAKEN_COLOR.r > 0.8 and DamageNumbers.TAKEN_COLOR.g < 0.4, "the received one is red")
	assert_true(DamageNumbers.COLORS[DamageNumbers.Kind.KILL].g > 0.8, "death is not red")
	numbers.free()


func test_number_pops_from_1_4_to_1_in_80_ms() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	var label: Label = numbers.add_number(1, Vector3.ZERO, 100)
	assert_near(label.scale.x, DamageNumbers.POP_SCALE, 0.01, "it is born 40 % magnified")
	numbers.advance(DamageNumbers.POP_SECONDS)
	assert_near(label.scale.x, 1.0, 0.01, "and at 80 ms it is at its size")
	numbers.free()


func test_marker_is_thick_and_every_variant_draws() -> void:
	assert_true(HitMarker.LINE_WIDTH >= 4.0, "thicker marks")
	var marker := HitMarker.new()
	marker.size = Vector2(200.0, 200.0)
	_root.add_child(marker)
	for kind: int in [HitMarker.Kind.HIT, HitMarker.Kind.HEAVY, HitMarker.Kind.BLOCKED, HitMarker.Kind.KILL,
			HitMarker.Kind.PARRY]:
		marker.show_marker(kind)
		assert_true(marker.is_active(), "variant %d" % kind)
		assert_eq(marker.get_variant(), kind)
	assert_true(HitMarker.COLORS[HitMarker.Kind.PARRY] != HitMarker.COLORS[HitMarker.Kind.BLOCKED],
			"parry and block are told apart by color")
	marker.free()
