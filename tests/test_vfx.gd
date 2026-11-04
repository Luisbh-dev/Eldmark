extends TestCase
## Tests for the hit effects (ART-09): that every scene in [code]scenes/vfx/[/code] loads, that the
## life cycle of [VfxEffect] (play, finish, play again without instancing), the reuse pool
## ([VfxPool]), the trail ([WeaponTrail]), the charge aura ([ChargeAura]), the dust ([DustKick]) and
## the palette ([VfxPalette]) do what they say, and that the design numbers set by the art review are
## met (no bubbles, maximum durations and ranges).
## [br][br]
## The test runner is headless (no renderer): here we do not check how the effects look (the strips in
## [code]scenes/tests/vfx_preview.tscn[/code] show that), only that the mechanics are correct and that
## no scene drags along missing resources.

const EFFECT_SCENES: Dictionary = {
	"hit_metal_spark": "res://scenes/vfx/hit_metal_spark.tscn",
	"hit_flesh": "res://scenes/vfx/hit_flesh.tscn",
	"hit_cloth": "res://scenes/vfx/hit_cloth.tscn",
	"hit_block_wood": "res://scenes/vfx/hit_block_wood.tscn",
	"parry_flash": "res://scenes/vfx/parry_flash.tscn",
	"dust_kick": "res://scenes/vfx/dust_kick.tscn",
	"charge_aura": "res://scenes/vfx/charge_aura.tscn",
}
const TRAIL_SCENE: String = "res://scenes/vfx/weapon_trail.tscn"
const SHADERS_DIR: String = "res://scenes/vfx/shaders"
## Time step used to advance the effects by hand (60 frames per second).
const STEP: float = 1.0 / 60.0

var _spawned: Array[Node] = []


func after_each() -> void:
	for node: Node in _spawned:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_spawned.clear()


# --- Scenes -----------------------------------------------------------------------------------

func test_every_effect_scene_loads_with_an_effect_root() -> void:
	for key: String in EFFECT_SCENES:
		var scene: PackedScene = load(EFFECT_SCENES[key]) as PackedScene
		assert_not_null(scene, "%s loads" % key)
		if scene == null:
			continue
		var effect: VfxEffect = _spawn(scene)
		assert_not_null(effect, "%s has a VfxEffect at the root" % key)
		if effect == null:
			continue
		assert_false(effect.is_playing(), "%s does not play when created" % key)
		assert_false(effect.visible, "%s is hidden while it is not playing" % key)


func test_trail_scene_loads_with_a_trail_root() -> void:
	var scene: PackedScene = load(TRAIL_SCENE) as PackedScene
	assert_not_null(scene, "weapon_trail loads")
	var trail: WeaponTrail = scene.instantiate() as WeaponTrail
	assert_not_null(trail, "the root is a WeaponTrail")
	if trail != null:
		_spawned.append(trail)
		assert_not_null(trail.material_override, "it carries the trail material")


func test_effects_use_only_shader_materials_that_animate_per_instance() -> void:
	# Shapes animated by progress share a material across all copies: the progress has to be a per-instance
	# shader parameter, or each copy would overwrite the others.
	for key: String in EFFECT_SCENES:
		var effect: VfxEffect = _spawn(load(EFFECT_SCENES[key]) as PackedScene)
		for node: Node in effect.find_children("*", "MeshInstance3D", true, false):
			if not node.has_meta(VfxEffect.META_TIME):
				continue
			var instance: MeshInstance3D = node as MeshInstance3D
			var material: ShaderMaterial = instance.material_override as ShaderMaterial
			assert_not_null(material, "%s/%s has a ShaderMaterial" % [key, node.name])
			if material == null:
				continue
			assert_true(material.shader.code.contains("instance uniform float progress"),
					"%s/%s: the shader has the instance parameter progress" % [key, node.name])
			var timing: Vector2 = node.get_meta(VfxEffect.META_TIME)
			assert_true(timing.y > 0.0, "%s/%s lasts longer than zero" % [key, node.name])


func test_every_shader_file_has_a_matching_material_use() -> void:
	# No shader may be left over (each one is used by some generated material) and every material must
	# reference one that exists.
	var shader_files: PackedStringArray = DirAccess.get_files_at(SHADERS_DIR)
	var used: Dictionary[String, bool] = {}
	for file: String in DirAccess.get_files_at("res://scenes/vfx/materials"):
		if not file.ends_with(".tres"):
			continue
		var material: ShaderMaterial = load("res://scenes/vfx/materials/" + file) as ShaderMaterial
		assert_not_null(material, "%s loads" % file)
		if material != null and material.shader != null:
			used[material.shader.resource_path.get_file()] = true
	for file: String in shader_files:
		if file.ends_with(".gdshader"):
			assert_true(used.has(file), "%s is used by some material" % file)


# --- Design: no bubbles, durations and ranges --------------------------------------------------

func test_rings_are_thin_edges_in_the_impact_plane_never_bubbles() -> void:
	# The ring does not face the camera (billboard) and has no soft fill: that was what read as a bubble.
	for key: String in ["hit_block_wood", "parry_flash", "charge_aura"]:
		var effect: VfxEffect = _spawn(load(EFFECT_SCENES[key]) as PackedScene)
		for node: Node in effect.find_children("*", "MeshInstance3D", true, false):
			var material: ShaderMaterial = (node as MeshInstance3D).material_override as ShaderMaterial
			if material == null or material.get_shader_parameter("mode") == null 					or int(material.get_shader_parameter("mode")) != 1:
				continue
			assert_false(bool(material.get_shader_parameter("billboard")),
					"%s/%s: the ring is oriented by the normal, it does not face the camera" % [key, node.name])
			var fill: Variant = material.get_shader_parameter("ring_fill")
			assert_true(fill == null or float(fill) == 0.0, "%s/%s: no fill" % [key, node.name])


func test_parry_and_block_have_the_designed_size_and_time() -> void:
	var parry: VfxEffect = _spawn(load(EFFECT_SCENES["parry_flash"]) as PackedScene)
	assert_true(parry.duration <= 0.25, "the hitstop lasts 0.25 s or less (%.2f)" % parry.duration)
	var shock: MeshInstance3D = parry.get_node("Shockwave") as MeshInstance3D
	assert_true((shock.mesh as QuadMesh).size.x >= 1.2, "the hitstop wave measures 1.2 m or more")
	assert_true((shock.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.2001, "and lasts 0.2 s or less")
	assert_true(parry.has_node("Lens"), "the hitstop carries the horizontal lens flare")
	var block: VfxEffect = _spawn(load(EFFECT_SCENES["hit_block_wood"]) as PackedScene)
	var half_ring: MeshInstance3D = block.get_node("HalfRing") as MeshInstance3D
	assert_true((half_ring.mesh as QuadMesh).size.x >= 0.8, "the block half-ring measures 0.8 m or more")
	assert_true((half_ring.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.2001, "and lasts 0.2 s or less")
	var material: ShaderMaterial = half_ring.material_override as ShaderMaterial
	assert_true(float(material.get_shader_parameter("ring_arc")) < 0.6, "it is a half ring, not a full one")
	assert_true(float(material.get_shader_parameter("ring_squash")) < 1.0, "and flattened")
	# The block flash is moved forward toward the camera: the shield does not cut it off.
	var flash: MeshInstance3D = block.get_node("Flash") as MeshInstance3D
	var flash_material: ShaderMaterial = flash.material_override as ShaderMaterial
	assert_true(float(flash_material.get_shader_parameter("push")) >= 0.1, "the flash is moved forward 0.1 m or more")


func test_particles_do_not_fly_further_than_designed() -> void:
	# Maximum range of a particle: with linear damping, v*t - d*t^2/2 (or v^2 / 2d if it stops earlier).
	assert_true(_max_travel("hit_metal_spark", "Sparks") <= 1.8, "the sparks do not go past 1.8 m")
	assert_true(_max_travel("hit_block_wood", "Splinters") <= 1.5, "the splinters do not go past 1.5 m")
	assert_true(_max_travel("hit_flesh", "Drops") <= 0.45, "the blood drops do not go past 0.45 m")
	var flesh: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	assert_true(flesh.duration <= 0.4, "the flesh lasts 0.4 s or less")
	var jet: MeshInstance3D = flesh.get_node("Jet") as MeshInstance3D
	var material: ShaderMaterial = jet.material_override as ShaderMaterial
	var pivot: Vector2 = material.get_shader_parameter("pivot")
	assert_true((jet.mesh as QuadMesh).size.x * 0.5 + pivot.x <= 0.41, "the spurt measures 0.4 m or less")
	assert_true((jet.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.2001, "and lasts 0.2 s or less")


func test_flesh_jets_pick_a_variant_per_shot_and_follow_the_blow() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var jet: MeshInstance3D = effect.get_node("Jet") as MeshInstance3D
	var seen: Dictionary[String, bool] = {}
	for shot: int in 8:
		effect.play_at(Vector3.ZERO, Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0))
		seen["%s/%s" % [jet.get_instance_shader_parameter(&"variant"), jet.get_instance_shader_parameter(&"flip")]] = true
		effect.reset()
	assert_eq(seen.size(), 8, "eight shots in a row give eight different spurts (4 variants times 2 mirrors)")
	effect.play_at(Vector3.ZERO, Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0))
	assert_vec_near(effect.global_transform.basis.x, Vector3(1.0, 0.0, 0.0), 0.001, "+X follows the hit direction")
	assert_vec_near(effect.global_transform.basis.z, Vector3(0.0, 0.0, 1.0), 0.001, "+Z follows the normal")
	assert_true(effect.global_transform.basis.is_conformal(), "undeformed")


func test_metal_spark_cone_leans_along_the_slash() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_metal_spark"]) as PackedScene)
	var normal: Vector3 = Vector3(0.0, 0.0, 1.0)
	effect.play_at(Vector3.ZERO, normal, Vector3(-1.0, 0.0, 0.0))
	var axis: Vector3 = effect.global_transform.basis.z
	assert_true(axis.x < -0.3, "the cone leans toward where the slash was going (%s)" % axis)
	assert_true(axis.dot(normal) > 0.5, "while still facing out of the surface")
	var contact: MeshInstance3D = effect.get_node("ContactGlow") as MeshInstance3D
	assert_true((contact.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.0601, "the contact point lasts 0.06 s or less")


# --- Life cycle -------------------------------------------------------------------------------

func test_effect_plays_finishes_and_replays_without_new_nodes() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_metal_spark"]) as PackedScene)
	var children_before: int = effect.get_child_count()
	var finished_count: Array[int] = [0]
	effect.finished.connect(func() -> void: finished_count[0] += 1)
	for round_index: int in 3:
		effect.play()
		assert_true(effect.is_playing(), "plays after play (round %d)" % round_index)
		assert_true(effect.visible, "it is visible while playing")
		_advance(effect, effect.duration + 0.5)
		assert_false(effect.is_playing(), "finishes on its own (round %d)" % round_index)
		assert_false(effect.visible, "it hides again")
	assert_eq(finished_count[0], 3, "emits finished once per round")
	assert_eq(effect.get_child_count(), children_before, "reusing it creates no nodes")


func test_shapes_run_progress_from_zero_to_one() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["parry_flash"]) as PackedScene)
	var ring: MeshInstance3D = effect.get_node("Shockwave") as MeshInstance3D
	assert_false(ring.visible, "the wave is hidden before being played")
	effect.play()
	_advance(effect, 0.07)
	assert_true(ring.visible, "the wave is visible at 0.07 s")
	var progress: Variant = ring.get_instance_shader_parameter(&"progress")
	assert_true(float(progress) > 0.1 and float(progress) < 0.9, "its progress is mid-way (%s)" % progress)
	_advance(effect, 0.3)
	assert_false(ring.visible, "the wave hides when its duration ends")


func test_delayed_shape_waits_for_its_start() -> void:
	# The flesh's side spurt starts 0.04 s after the main one.
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var side: MeshInstance3D = effect.get_node("JetSide") as MeshInstance3D
	effect.play()
	_advance(effect, 0.02)
	assert_false(side.visible, "the side spurt has not started yet at 0.02 s")
	_advance(effect, 0.05)
	assert_true(side.visible, "the side spurt is already visible at 0.07 s")


func test_play_at_points_plus_z_along_the_normal() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var normals: Array[Vector3] = [
		Vector3.UP, Vector3(1.0, 0.0, 0.0), Vector3(0.3, 0.2, -1.0).normalized(),
		Vector3.DOWN, Vector3(0.0, 0.0, 1.0),
	]
	for normal: Vector3 in normals:
		effect.play_at(Vector3(1.0, 2.0, 3.0), normal)
		assert_vec_near(effect.global_transform.basis.z, normal, 0.001, "+Z follows the normal %s" % normal)
		assert_vec_near(effect.global_position, Vector3(1.0, 2.0, 3.0), 0.001, "it is at the point")
		assert_true(effect.global_transform.basis.is_conformal(), "the basis is not deformed")
		effect.reset()
	# A zero normal breaks nothing.
	effect.play_at(Vector3.ZERO, Vector3.ZERO)
	assert_true(effect.is_playing(), "with a zero normal it still plays")


func test_tint_reaches_children_by_weight() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var jet: MeshInstance3D = effect.get_node("Jet") as MeshInstance3D
	var red: Color = effect.tint
	var applied: Color = jet.get_instance_shader_parameter(&"tint")
	assert_near(applied.r, red.r, 0.001, "the spurt takes the flesh red")
	assert_near(applied.g, red.g, 0.001, "...and the green")
	# Recoloring: the spurt follows the tint.
	effect.tint = Color(0.8, 0.75, 0.6)
	var cloth: Color = jet.get_instance_shader_parameter(&"tint")
	assert_near(cloth.r, 0.8, 0.001, "it takes the new color")
	assert_near(cloth.b, 0.6, 0.001, "...in the blue too")


func test_a_disabled_part_does_not_fire_with_its_cue() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	var ring: MeshInstance3D = dust.get_node("Ring") as MeshInstance3D
	dust.play_landing(Vector3.ZERO, 0.3)
	_advance(dust, 0.1)
	assert_false(ring.visible, "a soft fall does not raise the ring")
	dust.reset()
	dust.play_landing(Vector3.ZERO, 1.0)
	_advance(dust, 0.1)
	assert_true(ring.visible, "a hard fall does")
	assert_true((ring.mesh as QuadMesh).size.x <= 1.2001, "and the ring measures 1.2 m or less")


# --- Reuse pool -------------------------------------------------------------------------------

func test_pool_reuses_copies_and_never_grows() -> void:
	var pool := VfxPool.new()
	_spawned.append(pool)
	tree.root.add_child(pool)
	pool.setup(load(EFFECT_SCENES["hit_block_wood"]) as PackedScene, 3)
	assert_eq(pool.get_items().size(), 3, "creates three copies")
	var seen: Dictionary[int, bool] = {}
	for shot: int in 10:
		var effect: VfxEffect = pool.spawn(Vector3(float(shot), 0.0, 0.0), Vector3.UP)
		assert_not_null(effect, "spawn returns an effect")
		seen[effect.get_instance_id()] = true
		assert_true(pool.get_active_count() <= 3, "there are never more than three playing")
	assert_eq(seen.size(), 3, "ten shots with three copies: only those three are seen")
	assert_eq(pool.get_child_count(), 3, "nothing new is instanced")
	pool.release_all()
	assert_eq(pool.get_active_count(), 0, "release_all turns them off")


func test_pool_takes_a_free_copy_before_restarting_a_playing_one() -> void:
	var pool := VfxPool.new()
	_spawned.append(pool)
	tree.root.add_child(pool)
	pool.setup(load(EFFECT_SCENES["hit_metal_spark"]) as PackedScene, 2)
	var first: VfxEffect = pool.spawn(Vector3.ZERO)
	var second: VfxEffect = pool.spawn(Vector3.ONE)
	assert_true(first != second, "with one free, the first is not overwritten")
	_advance(first, first.duration + 0.5)
	_advance(second, second.duration + 0.5)
	assert_eq(pool.get_active_count(), 0, "when they finish they become free")
	var third: VfxEffect = pool.spawn(Vector3.ZERO)
	assert_not_null(third, "it can be requested again")


func test_pool_keeps_the_scene_tint_unless_told_otherwise() -> void:
	var pool := VfxPool.new()
	_spawned.append(pool)
	tree.root.add_child(pool)
	var scene: PackedScene = load(EFFECT_SCENES["hit_flesh"]) as PackedScene
	var reference: VfxEffect = _spawn(scene)
	pool.setup(scene, 2)
	for item: VfxEffect in pool.get_items():
		assert_eq(item.tint, reference.tint, "the pool does not overwrite the scene's tint (the flesh is red)")
	pool.set_tint(Color(0.5, 0.5, 0.5))
	for item: VfxEffect in pool.get_items():
		assert_eq(item.tint, Color(0.5, 0.5, 0.5), "set_tint tints all the copies")


# --- Trail ------------------------------------------------------------------------------------

func test_trail_draws_a_ribbon_while_the_target_moves_and_fades_out() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	assert_false(trail.is_active(), "inactive when created")
	trail.begin(target)
	# The blade sweeps a half-turn arc in 0.25 s.
	for index: int in 15:
		target.rotation.y = float(index) / 15.0 * PI
		trail._process(STEP)
	assert_true(trail.is_active(), "active while following the weapon")
	assert_true(trail.visible, "visible")
	var mesh: ImmediateMesh = trail.mesh as ImmediateMesh
	assert_eq(mesh.get_surface_count(), 1, "one surface with the ribbon")
	assert_true(mesh.get_aabb().size.length() > 0.3, "and the ribbon spans the arc (%s)" % mesh.get_aabb().size)
	trail.end()
	for index: int in 30:
		trail._process(STEP)
	assert_false(trail.is_active(), "turns itself off after max_age")
	assert_false(trail.visible, "and hides")
	assert_eq(mesh.get_surface_count(), 0, "no surfaces")


func test_trail_needs_three_samples_to_draw_and_tapers_its_tail() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	var mesh: ImmediateMesh = trail.mesh as ImmediateMesh
	for index: int in 2:
		target.rotation.y = float(index) * 0.15
		trail._process(STEP)
	assert_eq(mesh.get_surface_count(), 0, "with two samples nothing is drawn (it would be a straight quad)")
	target.rotation.y = 0.3
	trail._process(STEP)
	assert_eq(mesh.get_surface_count(), 1, "with three it is")
	assert_eq(trail.min_samples, 3, "the minimum is three")
	assert_true(trail.max_age <= 0.12, "the tail lasts 0.12 s or less")


func test_trail_min_speed_ignores_a_slow_blade_and_breaks_between_swings() -> void:
	var trail: WeaponTrail = _spawn_trail()
	trail.min_speed = 5.0
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	# Slowly (0.2 m/s at the tip): it leaves no ribbon.
	for index: int in 20:
		target.rotation.y = float(index) * 0.004
		trail._process(STEP)
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 0, "a slow blade leaves no trail")
	# Fast (the tip 0.9 m from the axis, a turn of 0.12 rad per frame is about 6.5 m/s): it does.
	for index: int in 10:
		target.rotation.y += 0.12
		trail._process(STEP)
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 1, "a fast blade does")
	trail.clear()
	assert_false(trail.is_active(), "clear turns it off at once")


func test_trail_cuts_at_a_pose_jump_and_caps_its_length() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	for index: int in 6:
		target.rotation.y = float(index) * 0.2
		trail._process(STEP)
	assert_true(trail._times.size() >= 3, "there is a ribbon before the jump")
	# A pose jump of several meters in one frame is not a slash: it cuts the ribbon, it does not stretch a cable.
	target.position = Vector3(8.0, 0.0, 0.0)
	trail._process(STEP)
	assert_true(trail._times.size() < 3, "after the jump no ribbon remains joined to the previous one")
	# A very long arc is trimmed at the old end.
	trail.clear()
	trail.max_length = 0.5
	trail.max_age = 5.0
	trail.begin(target)
	for index: int in 12:
		target.position = Vector3(8.0 + float(index) * 0.3, 0.0, 0.0)
		trail._process(STEP)
	var length: float = 0.0
	for index: int in range(1, trail._tips.size()):
		length += trail._tips[index].distance_to(trail._tips[index - 1])
	assert_true(length <= 0.5 + 0.35, "the arc that is drawn does not exceed max_length (%.2f)" % length)


func test_trail_axial_motion_is_marked_as_not_lateral() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	# A thrust: the blade (X axis) advances along its own axis.
	for index: int in 5:
		target.position = Vector3(float(index) * 0.15, 0.0, 0.0)
		trail._process(STEP)
	assert_true(trail._lateral.size() >= 3, "there are samples")
	assert_true(trail._lateral[trail._lateral.size() - 1] < 0.1, "axial motion does not paint width")


func test_trail_colors_follow_the_realm() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var seen: Dictionary[String, bool] = {}
	for realm: int in [0, NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			VfxPalette.REALM_ELDRUN]:
		trail.set_realm(realm)
		var edge: Color = trail.get_instance_shader_parameter(&"edge_color")
		seen[edge.to_html()] = true
	assert_eq(seen.size(), 5, "each realm has its own trail color")
	var vardheim: Color = VfxPalette.trail(NetProtocol.Realm.VARDHEIM)[1]
	assert_true(vardheim.b > 0.95 and vardheim.g > 0.7 and vardheim.r > 0.4 and vardheim.r < 0.6,
			"Vardheim is ice blue (%s), not cobalt" % vardheim)


# --- Charge aura ------------------------------------------------------------------------------

func test_charge_aura_pulses_once_at_full_charge_and_bursts_on_release() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	assert_not_null(aura, "the root is a ChargeAura")
	var pulse: MeshInstance3D = aura.get_node("PulseWave") as MeshInstance3D
	var burst: MeshInstance3D = aura.get_node("ReleaseWave") as MeshInstance3D
	aura.play()
	aura.set_charge(0.4)
	_advance(aura, 0.3)
	assert_true(aura.is_playing(), "the aura keeps going (it is continuous)")
	assert_false(pulse.visible, "without a full charge there is no pulse")
	aura.set_charge(1.0)
	_advance(aura, 0.1)
	assert_true(pulse.visible, "with a full charge the pulse plays")
	_advance(aura, 0.6)
	assert_false(pulse.visible, "the pulse ends")
	aura.set_charge(1.0)
	_advance(aura, 0.1)
	assert_false(pulse.visible, "and does not repeat while it stays full")
	aura.release()
	_advance(aura, 0.1)
	assert_true(burst.visible, "on release there is a burst")
	_advance(aura, 3.0)
	assert_false(aura.is_playing(), "after release it turns off completely")


func test_charge_aura_is_in_the_weapon_not_a_shell_around_the_body() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	assert_false(aura.has_node("Shell"), "there is no shell of strands over the body")
	assert_true(aura.has_node("Blade/BladeGlow"), "the glow is on the blade")
	assert_true(aura.has_node("Blade/Motes"), "the motes are absorbed into the blade")
	assert_true(aura.has_node("Rune"), "and the ground rune remains")
	# With a weapon, everything on the blade hangs from it and follows it.
	var weapon := Node3D.new()
	_spawned.append(weapon)
	tree.root.add_child(weapon)
	aura.set_weapon(weapon)
	assert_false(aura.has_node("Blade"), "the blade no longer hangs from the character")
	assert_not_null(weapon.get_node_or_null("Blade/BladeGlow"), "it hangs from the weapon")
	aura.play()
	aura.set_charge(0.7)
	var glow: MeshInstance3D = weapon.get_node("Blade/BladeGlow") as MeshInstance3D
	assert_near(float(glow.get_instance_shader_parameter(&"charge")), 0.7, 0.001, "the blade glow grows with the charge")
	assert_true(weapon.get_node("Blade").visible, "the blade is visible while playing")
	aura.stop()
	_advance(aura, 3.0)
	assert_false(weapon.get_node("Blade").visible, "and hides when turned off")


func test_charge_aura_scales_particles_with_charge() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	var motes: GPUParticles3D = aura.get_node("Blade/Motes") as GPUParticles3D
	aura.play()
	aura.set_charge(0.0)
	var low: float = motes.amount_ratio
	aura.set_charge(1.0)
	assert_true(motes.amount_ratio > low, "with more charge more motes come out (%.2f -> %.2f)" % [low, motes.amount_ratio])
	assert_near(aura.get_charge(), 1.0, 0.0001, "get_charge returns the last charge")
	aura.stop()


# --- Dust -------------------------------------------------------------------------------------

func test_dust_kick_landing_and_dodge_are_different_shapes() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	assert_not_null(dust, "the root is a DustKick")
	var spray: GPUParticles3D = dust.get_node("Spray") as GPUParticles3D
	var puffs: GPUParticles3D = dust.get_node("Puffs") as GPUParticles3D
	var crescent: MeshInstance3D = dust.get_node("Crescent") as MeshInstance3D
	dust.play_landing(Vector3(2.0, 0.0, 2.0), 1.0)
	assert_vec_near(dust.global_transform.basis.z, Vector3.UP, 0.001, "the landing has +Z pointing up")
	_advance(dust, 0.05)
	assert_true(puffs.emitting, "the landing opens the puffs in a ring")
	assert_false(spray.emitting, "and does not kick up the spray backward")
	assert_false(crescent.visible, "nor the crescent")
	dust.reset()
	dust.play_dodge(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 1.0)
	assert_vec_near(dust.global_transform.basis.z, Vector3.UP, 0.001, "the dodge also has +Z pointing up")
	assert_vec_near(dust.global_transform.basis.y, Vector3(0.0, 0.0, 1.0), 0.001,
			"and +Y pointing backward (opposite to the movement)")
	_advance(dust, 0.05)
	assert_true(spray.emitting, "the dodge does kick up the spray")
	assert_true(crescent.visible, "and the crescent")
	assert_false(puffs.emitting, "but not the landing's ring of puffs")


func test_dust_color_comes_from_the_ground_not_the_realm() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	assert_false("realm" in dust, "the dust has no realm")
	dust.set_ground(&"sand")
	assert_eq(dust.tint, VfxPalette.ground(&"sand"), "the color is that of the ground material")
	dust.set_ground_color(Color(0.3, 0.4, 0.5))
	assert_eq(dust.tint, Color(0.3, 0.4, 0.5), "or the one read from the terrain")
	assert_eq(VfxGround.color_at(null, Vector3.ZERO, &"stone"), VfxPalette.ground(&"stone"),
			"with no terrain it falls back to the default material")
	var seen: Dictionary[String, bool] = {}
	for kind: StringName in VfxPalette.GROUND_KINDS:
		seen[VfxPalette.ground(kind).to_html()] = true
	assert_eq(seen.size(), VfxPalette.GROUND_KINDS.size(), "every ground material has its own color")


# --- Palette ----------------------------------------------------------------------------------

func test_palette_gives_distinct_colors_per_realm() -> void:
	var realms: Array[int] = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			VfxPalette.REALM_ELDRUN]
	var trail_edges: Dictionary[String, bool] = {}
	var auras: Dictionary[String, bool] = {}
	for realm: int in realms:
		var colors: Array[Color] = VfxPalette.trail(realm)
		assert_eq(colors.size(), 2, "the trail has two colors (realm %d)" % realm)
		trail_edges[colors[1].to_html()] = true
		auras[VfxPalette.aura(realm).to_html()] = true
	assert_eq(trail_edges.size(), realms.size(), "different trails")
	assert_eq(auras.size(), realms.size(), "different auras")
	# An unknown realm falls back to neutral and does not break.
	assert_eq(VfxPalette.trail(99).size(), 2, "an unknown realm has neutral colors")


# --- Helpers ----------------------------------------------------------------------------------

func _spawn(scene: PackedScene) -> VfxEffect:
	var effect: VfxEffect = scene.instantiate() as VfxEffect
	if effect == null:
		return null
	_spawned.append(effect)
	tree.root.add_child(effect)
	return effect


func _spawn_trail() -> WeaponTrail:
	var trail: WeaponTrail = (load(TRAIL_SCENE) as PackedScene).instantiate() as WeaponTrail
	_spawned.append(trail)
	tree.root.add_child(trail)
	return trail


# Maximum range (m) of the [param node_name] particles of the [param key] scene: the maximum initial
# speed with the minimum damping, over their lifetime (not counting gravity, which pulls them down).
func _max_travel(key: String, node_name: String) -> float:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES[key]) as PackedScene)
	var particles: GPUParticles3D = effect.get_node(node_name) as GPUParticles3D
	var process: ParticleProcessMaterial = particles.process_material as ParticleProcessMaterial
	var speed: float = process.initial_velocity_max
	var damping: float = maxf(process.damping_min, 0.001)
	var life: float = particles.lifetime
	var stop_time: float = speed / damping
	if stop_time <= life:
		return speed * speed / (2.0 * damping)
	return speed * life - 0.5 * damping * life * life


# Advances [param effect] by [param seconds] by hand, in one-frame steps (it does not wait for the
# engine: this way the test does not depend on the clock running).
func _advance(effect: VfxEffect, seconds: float) -> void:
	var steps: int = ceili(seconds / STEP)
	for step: int in steps:
		if effect.is_playing():
			effect._process(STEP)
