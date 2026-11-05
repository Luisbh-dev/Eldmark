extends TestCase
## Tests of the client's combat feel (UI-12, basic ART-09, CMB-11):
## [DpsMeter], [HitMarker], [DamageNumbers] (grouping within 0.3 s and a limited pool) and
## [CombatFeedback] with synthetic events: only a hit confirmed by the server produces
## a marker and a number, the shake and the flash go to whoever they belong to, the sound hooks
## fire, and the player's own action is detected without simulation signals (a correction that replays
## ticks does not duplicate effects).

const OWN_ID: int = 5
const OTHER_ID: int = 21
const THIRD_ID: int = 22
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"

var _root: Node3D
var _feedback: CombatFeedback
var _marker: HitMarker
var _numbers: DamageNumbers
var _canvas: CanvasLayer
var _rig: CameraRig
var _character: PlayerCharacter
var _sounds: Array[StringName] = []
var _dt: float = 1.0 / 60.0


func before_each() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_sounds.clear()
	_root = Node3D.new()
	_root.name = "CombatFeedbackTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	if is_instance_valid(_canvas):
		tree.root.remove_child(_canvas)
		_canvas.free()
	_root = null
	_canvas = null
	_feedback = null
	_marker = null
	_numbers = null
	_rig = null
	_character = null
	await wait_process_frames()


# --- Helpers --------------------------------------------------------------------------------

func _hit(victim: int, attacker: int, amount: int = 90, flags: int = 0, attack_id: int = 0,
		tick: int = 100) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.hit(victim, tick, attacker, amount, 0, flags, attack_id)


## Setup with marker, numbers, camera and local character (without a network client).
func _make_feedback(with_rig: bool = true) -> void:
	_canvas = CanvasLayer.new()
	tree.root.add_child(_canvas)
	_marker = HitMarker.new()
	_canvas.add_child(_marker)
	_numbers = DamageNumbers.new()
	_canvas.add_child(_numbers)
	_character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_root.add_child(_character)
	_character.position = Vector3(0.0, 0.0, 0.0)
	var mesh := MeshInstance3D.new()
	mesh.name = "Cuerpo"
	mesh.mesh = CapsuleMesh.new()
	_character.add_child(mesh)
	if with_rig:
		_rig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
		_rig.set_scripted_look(true)
		_root.add_child(_rig)
	_feedback = CombatFeedback.new()
	_root.add_child(_feedback)
	_feedback.setup(null, _rig, _character, _marker, _numbers)
	_feedback.set_own_net_id(OWN_ID)
	# Without a client there are no views of remotes: they are all in the same place, in front of the player.
	_feedback.position_resolver = func(_net_id: int) -> Vector3: return Vector3(0.0, 0.0, -3.0)
	_feedback.sound_requested.connect(func(sound: StringName, _at: Vector3) -> void:
		_sounds.append(sound))


# --- DpsMeter ---------------------------------------------------------------------------------

func test_dps_meter_sums_the_window_and_divides_by_the_elapsed_time() -> void:
	var meter := DpsMeter.new()
	assert_eq(meter.get_dps(100), 0.0, "without hits there is no DPS")
	meter.add_hit(60, 100)
	assert_near(meter.get_dps(60), 100.0, 0.001, "one hit: at least 1 s")
	meter.add_hit(120, 100)
	meter.add_hit(180, 100)
	assert_eq(meter.get_damage(180), 300)
	assert_near(meter.get_dps(180), 150.0, 0.001, "300 damage in 2 s")
	assert_eq(meter.get_hit_count(180), 3)


func test_dps_meter_over_a_full_window_matches_the_expected_figure() -> void:
	# A 90-damage hit per second for 40 s: the 30 s window gives 90 DPS.
	var meter := DpsMeter.new()
	for second: int in 40:
		meter.add_hit(60 * (second + 1), 90)
	var now: int = 60 * 40
	assert_eq(meter.get_hit_count(now), 30, "only the hits of the 30 s window fit")
	assert_near(meter.get_dps(now), 90.0, 0.001, "after 30 s in a row, the window's damage divided by 30")
	assert_eq(meter.get_total_damage(), 40 * 90, "the total since the start is not lost")
	assert_eq(meter.get_total_hits(), 40)


func test_dps_meter_forgets_old_hits_and_ignores_zero_damage() -> void:
	var meter := DpsMeter.new()
	meter.add_hit(10, 500)
	meter.add_hit(20, 0)
	meter.add_hit(30, -5)
	assert_eq(meter.get_hit_count(100), 1, "hits without damage do not count")
	assert_eq(meter.get_damage(10 + DpsMeter.WINDOW_TICKS - 1), 500, "inside the window")
	assert_eq(meter.get_damage(10 + DpsMeter.WINDOW_TICKS), 0, "past the window it is forgotten")
	assert_eq(meter.get_dps(10 + DpsMeter.WINDOW_TICKS), 0.0)
	meter.add_hit(5000, 10)
	meter.reset()
	assert_eq(meter.get_total_damage(), 0)
	assert_eq(meter.get_dps(5000), 0.0)


# --- HitMarker --------------------------------------------------------------------------------

func test_hit_marker_shows_each_variant_and_fades() -> void:
	var marker := HitMarker.new()
	_root.add_child(marker)
	assert_false(marker.is_active())
	assert_eq(marker.get_alpha(), 0.0)
	for kind: int in [HitMarker.Kind.HIT, HitMarker.Kind.HEAVY, HitMarker.Kind.BLOCKED,
			HitMarker.Kind.KILL]:
		marker.show_marker(kind)
		assert_true(marker.is_active())
		assert_eq(marker.get_variant(), kind)
		assert_eq(marker.get_alpha(), 1.0, "just shown, opaque")
		marker.advance(HitMarker.DURATIONS[kind] * 0.5)
		assert_near(marker.get_alpha(), 0.5, 0.01, "at half life, half opaque")
		marker.advance(HitMarker.DURATIONS[kind])
		assert_false(marker.is_active(), "and disappears")
	assert_true(HitMarker.DURATIONS[HitMarker.Kind.KILL] > HitMarker.DURATIONS[HitMarker.Kind.HIT],
			"the kill one lasts longer")


func test_hit_marker_can_be_disabled() -> void:
	var marker := HitMarker.new()
	_root.add_child(marker)
	marker.enabled = false
	marker.show_marker(HitMarker.Kind.HIT)
	assert_false(marker.is_active(), "disabled shows nothing")
	assert_eq(marker.get_shown_count(), 0)
	marker.enabled = true
	marker.show_marker(HitMarker.Kind.HIT)
	assert_true(marker.is_active())
	marker.enabled = false
	assert_false(marker.is_active(), "and on disabling it, any existing one is removed")


# --- DamageNumbers ----------------------------------------------------------------------------

func test_damage_numbers_group_hits_on_the_same_target_within_the_window() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	var first: Label = numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	numbers.advance(0.1)
	var second: Label = numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	assert_true(first == second, "the second hit is added to the same number")
	assert_eq(numbers.get_active_count(), 1)
	assert_eq(numbers.get_number_amount(0), 180)
	assert_eq(numbers.get_number_hits(0), 2)
	assert_eq(numbers.get_number_text(0), "180")
	numbers.advance(0.15)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 30)
	assert_eq(numbers.get_active_count(), 1, "0.25 s after the first it still groups")
	assert_eq(numbers.get_number_amount(0), 210)
	numbers.advance(0.1)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 40)
	assert_eq(numbers.get_active_count(), 2, "after 0.3 s from the first another number comes out")
	assert_eq(numbers.get_number_amount(1), 40)
	assert_eq(numbers.get_spawned_count(), 2)


func test_damage_numbers_do_not_group_different_targets_or_directions() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	numbers.add_number(THIRD_ID, Vector3.ZERO, 90)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 50, DamageNumbers.Kind.HIT, true)
	assert_eq(numbers.get_active_count(), 3, "different targets and damage dealt/received do not mix")


func test_damage_numbers_pool_is_bounded_and_recycles_the_oldest() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	for i: int in DamageNumbers.MAX_NUMBERS + 8:
		numbers.add_number(100 + i, Vector3.ZERO, i + 1)
	assert_eq(numbers.get_pool_size(), DamageNumbers.MAX_NUMBERS, "never more labels than the cap")
	assert_eq(numbers.get_active_count(), DamageNumbers.MAX_NUMBERS)
	assert_eq(numbers.get_number_amount(0), 9, "the 8 oldest were recycled")
	assert_eq(numbers.get_number_amount(DamageNumbers.MAX_NUMBERS - 1),
			DamageNumbers.MAX_NUMBERS + 8)
	var children: int = numbers.get_child_count()
	numbers.advance(DamageNumbers.LIFETIME_SECONDS + 0.1)
	assert_eq(numbers.get_active_count(), 0, "at the end of their life they go back to the pool")
	numbers.add_number(1, Vector3.ZERO, 5)
	assert_eq(numbers.get_pool_size(), DamageNumbers.MAX_NUMBERS, "and are reused")
	assert_eq(numbers.get_child_count(), children, "without creating new nodes")


func test_damage_numbers_can_be_disabled_and_show_custom_text() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	var label: Label = numbers.add_number(OTHER_ID, Vector3.ZERO, 0, DamageNumbers.Kind.BLOCKED,
			false, false, "Bloqueado")
	assert_eq(label.text, "Bloqueado")
	numbers.add_number(THIRD_ID, Vector3.ZERO, 120, DamageNumbers.Kind.HEAVY, false, true)
	assert_eq(numbers.get_number_text(1), "120!", "a critical carries the exclamation mark")
	numbers.enabled = false
	assert_eq(numbers.get_active_count(), 0, "disabling removes the existing ones")
	assert_null(numbers.add_number(OTHER_ID, Vector3.ZERO, 10), "and none is created")
	assert_eq(numbers.get_active_count(), 0)


# --- CombatFeedback: hits -------------------------------------------------------------------

func test_own_confirmed_hit_shows_marker_number_and_counts_dps() -> void:
	_make_feedback()
	var kills: Array[int] = []
	_feedback.hit_confirmed.connect(func(kind: int, amount: int, _e: NetMessages.EntityEvent) -> void:
		kills.append(kind * 1000 + amount))
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, CombatCatalog.attack_id(&"sword_light_1")),
			true)
	assert_true(_marker.is_active(), "marker when the hit is confirmed")
	assert_eq(_marker.get_variant(), HitMarker.Kind.HIT)
	assert_eq(kills, [HitMarker.Kind.HIT * 1000 + 90] as Array[int])
	assert_eq(_feedback.get_damage_in_window(), 90, "the DPS adds up the damage")
	assert_true(_sounds.has(CombatFeedback.SOUND_HIT_DEALT), "and the hit hook sounds")
	assert_false(_rig.is_shaking(), "dealing a hit does not shake the camera")


func test_hit_variants_follow_the_flags_and_the_attack() -> void:
	_make_feedback()
	var heavy: int = CombatCatalog.attack_id(&"sword_heavy")
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 90, 0, light)), HitMarker.Kind.HIT)
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 200, 0, heavy)), HitMarker.Kind.HEAVY)
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED,
			heavy)), HitMarker.Kind.BLOCKED, "blocked weighs more than heavy")
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED,
			light)), HitMarker.Kind.PARRY, "the parry has its own variant, distinct from the block")
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 90, NetMessages.EntityEvent.HIT_FLAG_LETHAL
			| NetMessages.EntityEvent.HIT_FLAG_BLOCKED, light)), HitMarker.Kind.KILL,
			"and a kill weighs more than everything")
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED), true)
	assert_eq(_numbers.get_number_text(0), CombatFeedback.TEXT_PARRIED)
	assert_true(_sounds.has(CombatFeedback.SOUND_PARRY))
	_feedback.handle_event(_hit(THIRD_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED), true)
	assert_eq(_numbers.get_number_text(1), CombatFeedback.TEXT_BLOCKED)
	assert_eq(_feedback.get_damage_in_window(), 0, "what is blocked and parried adds no DPS")


func test_events_of_others_do_not_produce_marker_number_or_shake() -> void:
	_make_feedback()
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 90), false)
	assert_false(_marker.is_active(), "a hit between others marks nothing")
	assert_eq(_numbers.get_active_count(), 0, "nor shows a number")
	assert_false(_rig.is_shaking(), "nor shakes the camera")
	assert_eq(_feedback.get_damage_in_window(), 0, "nor counts toward the DPS")
	assert_eq(_feedback.get_events_handled(), 1)


func test_nothing_happens_without_a_confirmed_event() -> void:
	_make_feedback()
	await wait_physics_frames(5)
	assert_false(_marker.is_active(), "without an event there is no marker")
	assert_eq(_numbers.get_active_count(), 0, "nor number")
	assert_eq(_feedback.get_dps(), 0.0)


func test_damage_taken_shakes_the_camera_and_signals_the_attacker() -> void:
	_make_feedback()
	var taken: Array[Vector2i] = []
	_feedback.damage_taken.connect(func(amount: int, attacker: int, _e: NetMessages.EntityEvent) -> void:
		taken.append(Vector2i(amount, attacker)))
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 120), true)
	assert_eq(taken, [Vector2i(120, OTHER_ID)] as Array[Vector2i])
	assert_true(_rig.is_shaking(), "the camera shakes on receiving")
	assert_false(_marker.is_active(), "and the impact marker is for your own hits")
	assert_eq(_numbers.get_active_count(), 1, "the damage received comes out as a red number")
	assert_true(_sounds.has(CombatFeedback.SOUND_HIT_TAKEN))
	assert_eq(_feedback.get_damage_in_window(), 0, "and does not count toward the DPS")


func test_camera_shake_decays_and_respects_the_option() -> void:
	_make_feedback()
	_rig.add_shake(0.1, 0.2)
	await wait_process_frames(2)
	assert_true(_rig.is_shaking())
	assert_true(_rig.get_shake_offset().length() <= 0.1 + 0.0001, "does not exceed the requested amplitude")
	_rig.add_shake(5.0, 0.2)
	await wait_process_frames(1)
	assert_true(_rig.get_shake_offset().length() <= CameraRig.MAX_SHAKE_AMPLITUDE + 0.0001,
			"and there is a cap")
	var waited: int = 0
	while _rig.is_shaking() and waited < 120:
		await wait_process_frames(1)
		waited += 1
	assert_false(_rig.is_shaking(), "lasts a short time")
	await wait_process_frames(1)
	assert_eq(_rig.get_shake_offset(), Vector2.ZERO, "and goes back to 0")
	_feedback.camera_shake_enabled = false
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 120), true)
	assert_false(_rig.is_shaking(), "with the option off it does not shake")
	_rig.shake_enabled = false
	_rig.add_shake(0.1, 0.2)
	assert_false(_rig.is_shaking(), "not from the own camera either")


func test_flash_tints_the_victim_briefly_and_cleans_up() -> void:
	_make_feedback()
	var mesh: MeshInstance3D = _character.get_node(^"Cuerpo") as MeshInstance3D
	assert_null(mesh.material_overlay)
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 50), true)
	assert_not_null(mesh.material_overlay, "the victim flashes")
	assert_true(_feedback.get_flashing_count() >= 1, "with all the visible meshes of its body")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 0.5)
	assert_not_null(mesh.material_overlay, "halfway it continues")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS)
	assert_null(mesh.material_overlay, "and is removed at the end")
	assert_eq(_feedback.get_flashing_count(), 0)
	for node: Node in _character.find_children("*", "MeshInstance3D", true, false):
		assert_null((node as MeshInstance3D).material_overlay, "no mesh stays tinted")
	_feedback.flash_enabled = false
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 50), true)
	assert_null(mesh.material_overlay, "no flash if the player turns it off")


func test_the_flash_is_white_additive_short_and_fades_out() -> void:
	_make_feedback()
	var mesh: MeshInstance3D = _character.get_node(^"Cuerpo") as MeshInstance3D
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 50), true)
	var material: StandardMaterial3D = mesh.material_overlay as StandardMaterial3D
	if not assert_not_null(material, "the victim flashes"):
		return
	assert_eq(material.blend_mode, BaseMaterial3D.BLEND_MODE_ADD, "adds light instead of tinting")
	assert_eq(Color(material.albedo_color, 1.0), Color.WHITE, "and it is white, not red (UI-50)")
	assert_true(CombatFeedback.FLASH_SECONDS <= 0.1, "lasts about 80 ms")
	assert_near(_feedback.get_flash_alpha(), CombatFeedback.FLASH_COLOR.a, 0.0001, "at full intensity at the start")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 0.5)
	assert_near(_feedback.get_flash_alpha(), CombatFeedback.FLASH_COLOR.a * 0.5, 0.001, "and falls in a straight line")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS)
	assert_eq(_feedback.get_flashing_count(), 0)


func test_the_flash_is_dimmer_in_hits_that_do_not_involve_the_local_player() -> void:
	_make_feedback()
	_feedback.flash(OWN_ID, CombatFeedback.FLASH_OTHERS_INTENSITY)
	var dim: float = _feedback.get_flash_alpha()
	assert_near(dim, CombatFeedback.FLASH_COLOR.a * CombatFeedback.FLASH_OTHERS_INTENSITY, 0.0001)
	_feedback.advance_flashes(1.0)
	_feedback.flash(OWN_ID)
	assert_true(_feedback.get_flash_alpha() > dim, "own hits, at full intensity")
	_feedback.advance_flashes(1.0)
	_feedback.flash(OWN_ID, 7.0)
	assert_near(_feedback.get_flash_alpha(), CombatFeedback.FLASH_COLOR.a, 0.0001, "without exceeding full")


func test_entity_damaged_is_emitted_for_every_hit_with_damage() -> void:
	_make_feedback()
	var damaged: Array[int] = []
	_feedback.entity_damaged.connect(func(net_id: int) -> void: damaged.append(net_id))
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 40), false)
	_feedback.handle_event(_hit(OWN_ID, THIRD_ID, 40), true)
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED), false)
	assert_eq(damaged, [OTHER_ID, OWN_ID] as Array[int], "what is blocked without damage does not count")


func test_death_kill_and_respawn_signals() -> void:
	_make_feedback()
	var deaths: Array[Vector2i] = []
	var kills: Array[int] = []
	var respawns: Array[int] = []
	_feedback.local_died.connect(func(killer: int, attack: int) -> void:
		deaths.append(Vector2i(killer, attack)))
	_feedback.kill_confirmed.connect(func(victim: int, _e: NetMessages.EntityEvent) -> void:
		kills.append(victim))
	_feedback.local_respawned.connect(func(point: int, _tick: int) -> void: respawns.append(point))
	_feedback.handle_event(NetMessages.EntityEvent.death(OTHER_ID, 100, THIRD_ID, 3), false)
	assert_eq(deaths.size(), 0, "another's death is not your own")
	_feedback.handle_event(NetMessages.EntityEvent.death(OWN_ID, 100, OTHER_ID, 3), true)
	assert_eq(deaths, [Vector2i(OTHER_ID, 3)] as Array[Vector2i])
	_feedback.handle_event(NetMessages.EntityEvent.kill(OTHER_ID, 100, OWN_ID, 3,
			PackedInt32Array()), true)
	assert_eq(kills, [OTHER_ID] as Array[int])
	_feedback.handle_event(NetMessages.EntityEvent.kill(OTHER_ID, 100, THIRD_ID, 3,
			PackedInt32Array([OWN_ID])), true)
	assert_eq(kills.size(), 1, "an assistant is not the killer")
	_feedback.handle_event(NetMessages.EntityEvent.respawn(THIRD_ID, 100, 0), false)
	assert_eq(respawns.size(), 0)
	_feedback.handle_event(NetMessages.EntityEvent.respawn(OWN_ID, 100, 2), true)
	assert_eq(respawns, [2] as Array[int])
	assert_true(_sounds.has(CombatFeedback.SOUND_DEATH))
	assert_true(_sounds.has(CombatFeedback.SOUND_RESPAWN))
	assert_true(_sounds.has(CombatFeedback.SOUND_KILL))


func test_options_disable_marker_and_numbers() -> void:
	_make_feedback()
	_feedback.hit_markers_enabled = false
	_feedback.damage_numbers_enabled = false
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90), true)
	assert_false(_marker.is_active())
	assert_eq(_numbers.get_active_count(), 0)
	assert_eq(_feedback.get_damage_in_window(), 90, "the DPS is measured the same")
	_feedback.hit_markers_enabled = true
	_feedback.damage_numbers_enabled = true
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90), true)
	assert_true(_marker.is_active())
	assert_eq(_numbers.get_active_count(), 1)


func test_dps_through_the_feedback_matches_the_expected_combo_figure() -> void:
	_make_feedback()
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	# A 90-damage hit every 36 ticks (the unlinked light 1) for 30 s.
	var tick: int = 100
	var total: int = 0
	while tick < 100 + DpsMeter.WINDOW_TICKS - 36:
		_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, light, tick), true)
		total += 90
		tick += 36
	assert_eq(_feedback.get_damage_in_window(), total)
	assert_near(_feedback.get_dps_meter().get_dps(tick), float(total) / 30.0, 3.0,
			"the measured DPS matches the one computed from the data")


# --- Own events on a remote wait for its draw tick ---------------------------

## Draw clock that reports the tick the test wants.
class FakeClock extends InterpolationClock:
	var fake_render_tick: float = 0.0

	func get_render_tick() -> float:
		return fake_render_tick


## Network client that connects to nothing: it provides the own id and the fake clock.
class FakeClient extends NetClient:
	var fake_clock: FakeClock = FakeClock.new()

	func get_net_id() -> int:
		return OWN_ID

	func get_interpolation_clock() -> InterpolationClock:
		return fake_clock


func _remote_spawn(net_id: int) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 10
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.display_name = "Remoto%d" % net_id
	var state := PlayerState.new()
	state.position = Vector3(0.0, 0.0, -6.0)
	state.grounded = true
	spawn.state = state
	return spawn


## Setup with a fake client and a remote ([constant OTHER_ID]) with its body, so that its
## flash and its position exist. The draw clock starts at [param render_tick].
func _make_feedback_with_remote(render_tick: float) -> FakeClient:
	_make_feedback()
	var client := FakeClient.new()
	client.fake_clock.fake_render_tick = render_tick
	_root.add_child(client)
	client.get_remote_world().on_spawn(_remote_spawn(OTHER_ID))
	_feedback.position_resolver = Callable()
	_feedback.setup(client, _rig, _character, _marker, _numbers)
	return client


## One physics step of the setup with the draw clock at [param render_tick].
func _step_feedback(client: FakeClient, render_tick: float) -> void:
	client.fake_clock.fake_render_tick = render_tick
	_feedback._physics_process(_dt)


func test_an_own_hit_on_a_remote_shows_the_flash_when_the_draw_tick_reaches_it() -> void:
	# C3/T6: the own HIT arrives as soon as it happens, but the remote is drawn a few ticks behind:
	# marker and number come out right away, the flash and the nameplate wait until it is seen receiving the hit.
	var client: FakeClient = _make_feedback_with_remote(92.0)
	var damaged: Array[int] = []
	_feedback.entity_damaged.connect(func(net_id: int) -> void: damaged.append(net_id))
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, 0, 100), true)
	assert_true(_marker.is_active(), "the marker comes out on arrival")
	assert_eq(_numbers.get_active_count(), 1, "and the number")
	assert_eq(_feedback.get_damage_in_window(), 90, "and the DPS")
	assert_eq(_feedback.get_flashing_count(), 0, "but the remote has not received the hit yet")
	assert_true(damaged.is_empty(), "nor has its health plate found out")
	_step_feedback(client, 99.0)
	assert_eq(_feedback.get_flashing_count(), 0, "one tick earlier, nothing")
	_step_feedback(client, 100.0)
	assert_true(_feedback.get_flashing_count() >= 1, "when the draw tick reaches that of the hit, it flashes")
	assert_eq(damaged, [OTHER_ID] as Array[int], "and its plate shows the health")
	_step_feedback(client, 101.0)
	assert_eq(damaged.size(), 1, "only once")


func test_own_death_and_kill_sounds_of_a_remote_wait_for_the_draw_tick() -> void:
	var client: FakeClient = _make_feedback_with_remote(80.0)
	_feedback.handle_event(NetMessages.EntityEvent.death(OTHER_ID, 100, OWN_ID, 2), true)
	_feedback.handle_event(NetMessages.EntityEvent.kill(OTHER_ID, 100, OWN_ID, 2, PackedInt32Array()),
			true)
	assert_false(_sounds.has(CombatFeedback.SOUND_DEATH), "the death of one who still looks alive does not sound")
	assert_false(_sounds.has(CombatFeedback.SOUND_KILL))
	_step_feedback(client, 100.0)
	assert_true(_sounds.has(CombatFeedback.SOUND_DEATH), "it sounds when it is seen falling")
	assert_true(_sounds.has(CombatFeedback.SOUND_KILL))


func test_what_is_about_the_local_player_or_already_due_is_not_delayed() -> void:
	var client: FakeClient = _make_feedback_with_remote(80.0)
	var damaged: Array[int] = []
	_feedback.entity_damaged.connect(func(net_id: int) -> void: damaged.append(net_id))
	# The local one is the victim: there is no remote to wait for.
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 90, 0, 0, 100), true)
	assert_true(_feedback.get_flashing_count() >= 1, "the hit received flashes on arrival")
	assert_eq(damaged, [OWN_ID] as Array[int])
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 2.0)
	assert_eq(_feedback.get_flashing_count(), 0)
	# A foreign event already comes timed by NetClient: it is applied as is.
	_feedback.handle_event(_hit(OTHER_ID, 33, 40, 0, 0, 100), false)
	assert_true(_feedback.get_flashing_count() >= 1, "a foreign event does not wait again")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 2.0)
	# An own hit whose tick has already been drawn flashes right away.
	client.fake_clock.fake_render_tick = 120.0
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, 0, 100), true)
	assert_true(_feedback.get_flashing_count() >= 1, "if the remote is already at that tick, there is no wait")


func test_rebinding_the_feedback_drops_the_pending_reactions() -> void:
	var client: FakeClient = _make_feedback_with_remote(50.0)
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, 0, 100), true)
	_feedback.setup(client, _rig, _character, _marker, _numbers)
	_step_feedback(client, 200.0)
	assert_eq(_feedback.get_flashing_count(), 0, "what was pending from the previous connection is discarded")


# --- CombatFeedback: own actions without signals ---------------------------------------------

func _floor() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(shape)
	_root.add_child(body)


func _input(tick: int, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.buttons = buttons
	return input.quantized()


func test_own_actions_are_detected_without_simulation_signals() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var changes: Array[int] = []
	var swings: Array[bool] = []
	_feedback.action_changed.connect(func(action: int, _id: int, _t: int, _prev: int) -> void:
		changes.append(action))
	_feedback.swing_active_changed.connect(func(active: bool, _id: int) -> void:
		swings.append(active))
	var light: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var tick: int = 1000
	for i: int in light.total_ticks + 4:
		await wait_physics_frames(1)
		tick += 1
		_character.simulate(_input(tick, PlayerInput.PRIMARY if i < 3 else 0), _dt)
		_feedback.observe_action()
	assert_eq(changes, [CombatState.Action.LIGHT, CombatState.Action.NONE] as Array[int],
			"the light attack starts and ends")
	assert_eq(swings, [true, false] as Array[bool], "the sweep is launched and cut once")
	assert_true(_sounds.has(CombatFeedback.SOUND_SWING))
	assert_false(_feedback.is_swing_active())


func test_swing_follows_the_active_window_exactly() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var light: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var active_ticks: Array[int] = []
	var tick: int = 2000
	# A few idle ticks so the character touches the ground (you do not attack in the air).
	for _i: int in 4:
		await wait_physics_frames(1)
		tick += 1
		_character.simulate(_input(tick, 0), _dt)
	for i: int in light.total_ticks + 2:
		await wait_physics_frames(1)
		tick += 1
		_character.simulate(_input(tick, PlayerInput.PRIMARY if i < 3 else 0), _dt)
		_feedback.observe_action()
		if _feedback.is_swing_active():
			active_ticks.append(i)
	assert_eq(active_ticks.size(), light.active_ticks, "active during the hit's ticks")
	assert_eq(active_ticks[0], light.windup_ticks, "starts right when the windup ends")


func test_replaying_ticks_does_not_duplicate_action_effects() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var changes: Array[int] = []
	_feedback.action_changed.connect(func(action: int, _id: int, _t: int, _prev: int) -> void:
		changes.append(action))
	# It plays up to the middle of the light attack and the state is noted.
	var tick: int = 3000
	await wait_physics_frames(1)
	var saved: PlayerState = _character.get_state()
	var inputs: Array[PlayerInput] = []
	for i: int in 8:
		tick += 1
		inputs.append(_input(tick, PlayerInput.PRIMARY if i < 3 else 0))
	for input: PlayerInput in inputs:
		await wait_physics_frames(1)
		_character.simulate(input, _dt)
	_feedback.observe_action()
	assert_eq(changes.size(), 1, "a single action started")
	# Reconciliation replays the same ticks from the saved state, within a single tick.
	await wait_physics_frames(1)
	_character.set_state(saved)
	for input: PlayerInput in inputs:
		_character.simulate(input, _dt)
	_feedback.observe_action()
	assert_eq(changes.size(), 1, "replaying the ticks does not repeat the effect: the key is the same")


func test_a_correction_that_shifts_the_start_of_a_dodge_does_not_repeat_the_effects() -> void:
	# T5: the input of the dodge edge is lost and the server substitutes it (repeats the previous
	# buttons): dodge one tick later. On adopting its state the start tick changes by 1 tick, but
	# it is the same dodge: a single warning and a single sound.
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var dodges: Array[int] = []
	_feedback.action_changed.connect(func(action: int, _id: int, tick: int, _prev: int) -> void:
		if action == CombatState.Action.DODGE:
			dodges.append(tick))
	# A few idle ticks so the character lands before dodging.
	for i: int in 12:
		await wait_physics_frames(1)
		_character.simulate(_input(4980 + i, 0), _dt)
	var saved: PlayerState = _character.get_state()
	var first_tick: int = 5001
	# The client predicts: it presses dodge on tick 5001 and holds it for 4 ticks.
	for i: int in 6:
		await wait_physics_frames(1)
		_character.simulate(_input(first_tick + i, PlayerInput.DODGE if i < 4 else 0), _dt)
		_feedback.observe_action()
	assert_eq(dodges, [first_tick] as Array[int], "the prediction starts the dodge on its tick")
	assert_eq(_sounds.count(CombatFeedback.SOUND_DODGE), 1)
	# The server did not receive the input of 5001 (the substitute repeats the previous buttons: none) and
	# sees the edge one tick later, with the button still pressed. Reconciliation adopts that state.
	await wait_physics_frames(1)
	_character.set_state(saved)
	for i: int in 6:
		_character.simulate(_input(first_tick + i, PlayerInput.DODGE if i >= 1 and i < 5 else 0), _dt)
	assert_eq(_character.combat.action_tick, first_tick + 1, "the server dodged one tick later")
	_feedback.observe_action()
	assert_eq(dodges, [first_tick] as Array[int], "there is no second warning of the same dodge")
	assert_eq(_sounds.count(CombatFeedback.SOUND_DODGE), 1, "nor a second sound")


func test_two_dodges_chained_by_the_buffer_are_two_actions() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var dodges: Array[int] = []
	_feedback.action_changed.connect(func(action: int, _id: int, tick: int, _prev: int) -> void:
		if action == CombatState.Action.DODGE:
			dodges.append(tick))
	var first_tick: int = 6001
	# Dodge and, during it, another press: the second comes out of the buffer when the first ends.
	for i: int in 60:
		await wait_physics_frames(1)
		var pressed: bool = i < 2 or (i >= 21 and i < 23)
		_character.simulate(_input(first_tick + i, PlayerInput.DODGE if pressed else 0), _dt)
		_feedback.observe_action()
	assert_eq(dodges.size(), 2, "two dodges, two warnings")
	assert_eq(_sounds.count(CombatFeedback.SOUND_DODGE), 2, "and two sounds")


func test_a_new_attack_in_the_combo_is_a_new_action() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var ids: Array[int] = []
	_feedback.action_changed.connect(func(action: int, id: int, _t: int, _prev: int) -> void:
		if action == CombatState.Action.LIGHT:
			ids.append(id))
	var light1: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var tick: int = 4000
	# First light attack, and another press inside its link window.
	var link_press: int = light1.combo_window_from() + 2
	for i: int in light1.total_ticks + 10:
		await wait_physics_frames(1)
		tick += 1
		var pressed: bool = i < 3 or (i >= link_press and i < link_press + 3)
		_character.simulate(_input(tick, PlayerInput.PRIMARY if pressed else 0), _dt)
		_feedback.observe_action()
	assert_eq(ids, [CombatCatalog.attack_id(&"sword_light_1"),
			CombatCatalog.attack_id(&"sword_light_2")] as Array[int], "the combo chains the second")
