extends TestCase
## Tests of the sound and effect hooks of [HumanoidVisual] (ART-11, ART-09): a remote's actions sound and
## are seen (sweep, dodge, ability), the charge aura follows the charge fraction, the heavy attack's trail lights up
## with its variant and the footsteps come from the feet on the surface being stepped on.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

var _nodes: Array[Node] = []
var _audio: CombatAudio
var _vfx: CombatVfx


func before_each() -> void:
	_audio = CombatAudio.new()
	tree.root.add_child(_audio)
	_nodes.append(_audio)
	_vfx = CombatVfx.new()
	tree.root.add_child(_vfx)
	_nodes.append(_vfx)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _make_remote(byte_holder: Array) -> HumanoidVisual:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	world.add_child(character)
	var visual: HumanoidVisual = HumanoidVisual.install(character)
	var weapon_id: int = CombatCatalog.weapon_id(&"sword_shield")
	visual.get_animator().set_remote_source(func() -> int: return int(byte_holder[0]),
			func() -> int: return weapon_id)
	return visual


static func _byte(action: int, phase: int = 0, step: int = 0) -> int:
	return action | (phase << 4) | (step << 6)


func test_a_remote_swing_sounds_with_the_delay_of_its_windup() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.LIGHT, ActionMachine.PHASE_WINDUP, 0)
	await wait_process_frames(2)
	assert_true(_audio.get_pending_count() + _audio.get_play_count(&"sword_swing_light") >= 1,
			"the remote's sweep was requested (delayed, waiting for the active window)")
	await tree.create_timer(0.3).timeout
	assert_eq(_audio.get_play_count(&"sword_swing_light"), 1, "and sounds once")
	holder[0] = 0
	await wait_process_frames(2)
	holder[0] = _byte(CombatState.Action.HEAVY, ActionMachine.PHASE_WINDUP, 0)
	await wait_process_frames(2)
	await tree.create_timer(0.45).timeout
	assert_eq(_audio.get_play_count(&"sword_swing_heavy"), 1, "the heavy sounds with its bank")


func test_a_remote_dodge_sounds_and_raises_dust() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.DODGE, 0, 1)
	await wait_process_frames(2)
	assert_eq(_audio.get_play_count(&"dodge_roll"), 1)
	assert_eq(_vfx.get_spawn_count(&"dust"), 1)


func test_a_remote_shield_wall_shows_its_arc() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(&"sword_shield"))
	var slot: int = 0
	for index: int in WeaponTicks.new().ability_ids.size():
		var ability: AbilityTicks = CombatCatalog.ability(weapon.ability_id(index))
		if ability != null and ability.name == &"shield_wall":
			slot = index
	holder[0] = _byte(CombatState.Action.ABILITY, 0, slot)
	await wait_process_frames(2)
	assert_eq(_vfx.get_spawn_count(&"wall"), 1, "a remote's shield wall is seen")


func test_charge_aura_follows_the_charge_and_releases_on_the_heavy_blow() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.CHARGE)
	await wait_process_frames(10)
	var aura: ChargeAura = visual.get_charge_aura()
	if not assert_not_null(aura, "the aura is created when charging starts"):
		return
	assert_true(aura.is_playing(), "and lights up")
	var early: float = aura.get_charge()
	await wait_process_frames(30)
	assert_true(aura.get_charge() > early, "it grows with the time the charge is seen")
	holder[0] = _byte(CombatState.Action.HEAVY, ActionMachine.PHASE_ACTIVE)
	await wait_process_frames(2)
	assert_true(not aura.is_playing() or aura.get_elapsed() < 1.0, "on releasing the hit it bursts and goes out")


func test_cancelled_charge_switches_the_aura_off_without_a_burst() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.CHARGE)
	await wait_process_frames(10)
	var aura: ChargeAura = visual.get_charge_aura()
	if not assert_not_null(aura):
		return
	holder[0] = 0
	await wait_process_frames(2)
	assert_false(aura.is_playing() and aura.get_charge() > 0.95, "canceling turns off the aura")


func test_the_heavy_swing_lights_the_heavy_trail() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.HEAVY, ActionMachine.PHASE_ACTIVE)
	await wait_process_frames(3)
	var sword: Node3D = WeaponProps.get_sword_node(visual.get_skeleton())
	var trail: SwordTrail = sword.get_node_or_null(^"SwordTrail") as SwordTrail
	if not assert_not_null(trail):
		return
	assert_true(trail.is_active() and trail.is_heavy(), "the heavy hit lights up the heavy trail")
	holder[0] = 0
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.LIGHT, ActionMachine.PHASE_ACTIVE, 0)
	await wait_process_frames(3)
	assert_true(trail.is_active() and not trail.is_heavy(), "a light one, the normal")


func test_hit_stop_on_a_visual_freezes_its_combat_clip() -> void:
	var holder: Array = [0]
	var visual: HumanoidVisual = _make_remote(holder)
	if not assert_not_null(visual):
		return
	await wait_process_frames(3)
	holder[0] = _byte(CombatState.Action.LIGHT, ActionMachine.PHASE_ACTIVE, 0)
	await wait_process_frames(4)
	var layer: CombatAnimationLayer = visual.get_animator().get_combat_layer()
	visual.start_hitstop(0.08)
	assert_true(layer.is_in_hitstop(), "hitstop is applied to the character's combat layer")
	await wait_process_frames(12)
	assert_false(layer.is_in_hitstop(), "and ends")


func test_footstep_surface_defaults_to_grass_on_a_plain_floor() -> void:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	assert_eq(FootstepSurface.kind_at(world, Vector3.ZERO), CombatSoundBank.SURFACE_GRASS,
			"without terrain or metadata, grass")


func test_a_collider_with_surface_metadata_decides_the_step() -> void:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var body := StaticBody3D.new()
	body.set_meta(FootstepSurface.META_SURFACE, &"wood")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10.0, 1.0, 10.0)
	shape.shape = box
	body.add_child(shape)
	world.add_child(body)
	body.position = Vector3(0.0, -0.5, 0.0)
	await wait_physics_frames(3)
	assert_eq(FootstepSurface.kind_at(world, Vector3(0.0, 0.05, 0.0)), CombatSoundBank.SURFACE_WOOD,
			"a wooden bridge sounds like wood")
