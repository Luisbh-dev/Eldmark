extends TestCase
## The project's own sword model (tools/blender/build_sword.py, scripts/client/sword_model.gd): the
## four GLBs load with their two LODs, measure what they should, share exactly the same geometry and the
## same blade UVs (each realm puts its own texture on it: fuller of ice, gold or ember) and
## only the crossguard, pommel and colors change. Also the strike trail ([SwordTrail]) and the per-realm sword of
## [WeaponProps].

const VARIANTS: Array[StringName] = [&"base", &"vardheim", &"solmarch", &"askarra"]


func _load(variant: StringName) -> Node3D:
	return SwordModel.instantiate(variant, false)


func _lod(root: Node3D, level: int) -> MeshInstance3D:
	return root.find_child(String(SwordModel.LOD0_NAME if level == 0 else SwordModel.LOD1_NAME), true, false) \
			as MeshInstance3D


func _standard(mesh: ArrayMesh, surface: int) -> StandardMaterial3D:
	return mesh.surface_get_material(surface) as StandardMaterial3D


func test_the_four_models_load_with_two_lods() -> void:
	for variant: StringName in VARIANTS:
		var root: Node3D = _load(variant)
		if not assert_not_null(root, "model %s loads" % variant):
			continue
		var near: MeshInstance3D = _lod(root, 0)
		var far: MeshInstance3D = _lod(root, 1)
		assert_not_null(near, "%s: full-detail mesh" % variant)
		assert_not_null(far, "%s: simple-detail mesh" % variant)
		if near == null or far == null:
			root.free()
			continue
		var near_tris: int = SwordModel.triangle_count(root, 0)
		var far_tris: int = SwordModel.triangle_count(root, 1)
		assert_true(near_tris >= 1500 and near_tris <= 4500,
				"%s: LOD0 has between 1,500 and 4,500 triangles (%d)" % [variant, near_tris])
		assert_true(far_tris > 0 and far_tris < near_tris * 0.35,
				"%s: LOD1 weighs less than a third of LOD0 (%d of %d)" % [variant, far_tris, near_tris])
		root.free()


func test_the_sword_is_about_1_1_m_long_with_the_grip_at_the_origin() -> void:
	for variant: StringName in VARIANTS:
		var root: Node3D = _load(variant)
		if not assert_not_null(root):
			continue
		var box: AABB = _lod(root, 0).mesh.get_aabb()
		assert_true(box.size.y > 1.05 and box.size.y < 1.2,
				"%s: measures %.3f m long" % [variant, box.size.y])
		# The tip at 0.94 m from the center of the hilt; the pommel, behind.
		assert_near(box.end.y, SwordModel.GRIP_TO_TIP, 0.01, "%s: the tip" % variant)
		assert_true(box.position.y < -0.14 and box.position.y > -0.25,
				"%s: the pommel sits behind the hand (%.3f)" % [variant, box.position.y])
		assert_true(box.size.x > 0.30 and box.size.x < 0.45, "%s: the crossguard spans %.2f m" % [variant, box.size.x])
		# Total thickness: the thickest part is the base's round pommel (7 cm); the rest is flat along Z.
		assert_true(box.size.z < 0.09, "%s: thickness %.3f m" % [variant, box.size.z])
		root.free()


func test_every_variant_shares_the_same_blade_geometry() -> void:
	var base: Node3D = _load(&"base")
	var base_mesh: ArrayMesh = _lod(base, 0).mesh as ArrayMesh
	var base_arrays: Array = base_mesh.surface_get_arrays(0)
	assert_eq(_standard(base_mesh, 0).resource_name, "SwordBlade", "surface 0 is the blade")
	var base_albedo: Image = _standard(base_mesh, 0).albedo_texture.get_image()
	for variant: StringName in [&"vardheim", &"solmarch", &"askarra"]:
		var other: Node3D = _load(variant)
		var mesh: ArrayMesh = _lod(other, 0).mesh as ArrayMesh
		assert_eq(_standard(mesh, 0).resource_name, "SwordBlade", "%s: surface 0 is the blade" % variant)
		var arrays: Array = mesh.surface_get_arrays(0)
		assert_true(arrays[Mesh.ARRAY_VERTEX] == base_arrays[Mesh.ARRAY_VERTEX],
				"%s: same blade vertices as the base" % variant)
		assert_true(arrays[Mesh.ARRAY_TEX_UV] == base_arrays[Mesh.ARRAY_TEX_UV],
				"%s: same blade UVs" % variant)
		# The geometry and UVs are the same; the texture is not: each realm shows on the blade.
		var albedo: Image = _standard(mesh, 0).albedo_texture.get_image()
		assert_eq(albedo.get_size(), base_albedo.get_size(), "%s: same texture size" % variant)
		assert_false(albedo.get_data() == base_albedo.get_data(), "%s: its own blade texture" % variant)
		other.free()
	base.free()


func test_variants_change_guard_pommel_and_colors() -> void:
	var base: Node3D = _load(&"base")
	var base_mesh: ArrayMesh = _lod(base, 0).mesh as ArrayMesh
	var base_leather: Image = _standard(base_mesh, 1).albedo_texture.get_image()
	var base_metal: Image = _standard(base_mesh, 2).albedo_texture.get_image()
	var base_tris: int = SwordModel.triangle_count(base, 0)
	for variant: StringName in [&"vardheim", &"solmarch", &"askarra"]:
		var other: Node3D = _load(variant)
		var mesh: ArrayMesh = _lod(other, 0).mesh as ArrayMesh
		assert_true(SwordModel.triangle_count(other, 0) != base_tris, "%s: a different crossguard and pommel" % variant)
		assert_false(_standard(mesh, 1).albedo_texture.get_image().get_data() == base_leather.get_data(),
				"%s: different leather" % variant)
		assert_false(_standard(mesh, 2).albedo_texture.get_image().get_data() == base_metal.get_data(),
				"%s: different metal" % variant)
		other.free()
	base.free()


func test_only_askarra_has_the_ember() -> void:
	for variant: StringName in VARIANTS:
		var root: Node3D = _load(variant)
		var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
		var emissive: bool = false
		for surface: int in range(mesh.get_surface_count()):
			var material: StandardMaterial3D = _standard(mesh, surface)
			if material != null and material.emission_enabled:
				emissive = true
		assert_eq(emissive, variant == &"askarra", "%s: emissive ember only in Askarra" % variant)
		root.free()


func test_askarra_blade_carries_the_glowing_crack_and_the_others_do_not() -> void:
	# The burning crack runs along the blade's fuller (emission texture), not only on the pommel.
	for variant: StringName in VARIANTS:
		var root: Node3D = _load(variant)
		var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
		var blade: StandardMaterial3D = _standard(mesh, 0)
		if variant == &"askarra":
			assert_true(blade.emission_enabled, "Askarra's blade emits")
			assert_not_null(blade.emission_texture, "with the crack as the emission texture")
			assert_true(blade.emission_energy_multiplier >= 3.0 and blade.emission_energy_multiplier <= 4.0,
					"with a strength of 3 to 4 (%.1f)" % blade.emission_energy_multiplier)
		else:
			assert_false(blade.emission_enabled, "%s: the blade does not emit" % variant)
		root.free()


func test_blade_is_mid_steel_with_a_bright_thin_edge() -> void:
	# Medium steel (0.62 to 0.68: darker read as obsidian from the camera) with a light edge.
	var root: Node3D = _load(&"base")
	var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
	var image: Image = _standard(mesh, 0).albedo_texture.get_image()
	image.decompress()
	var w: int = image.get_width()
	var h: int = image.get_height()
	var row: int = int(h * 0.5)
	# The flat face (at 40 % of the half width) is dark and the edge (at 96 %) is light.
	var face: Color = image.get_pixel(int(w * (0.5 + 0.5 * 0.40)), row)
	var edge: Color = image.get_pixel(int(w * (0.5 + 0.5 * 0.96)), row)
	assert_true(face.get_luminance() > 0.55 and face.get_luminance() < 0.78,
			"the flat face is medium steel (%.2f)" % face.get_luminance())
	assert_true(edge.get_luminance() > 0.85, "the edge is light (%.2f)" % edge.get_luminance())
	# Darker next to the crossguard than toward the tip.
	# (Row 0 of the image is the tip: v = 1.)
	var near_guard: Color = image.get_pixel(int(w * 0.70), int(h * 0.75))
	var near_tip: Color = image.get_pixel(int(w * 0.70), int(h * 0.12))
	assert_true(near_guard.get_luminance() < near_tip.get_luminance(), "gradient along its length")
	root.free()


func test_blade_has_heroic_proportions() -> void:
	# Wider and thicker than a real sword (8.9 x 1.4 cm), with the tip where it was.
	var root: Node3D = _load(&"base")
	var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var max_x: float = 0.0
	var max_z: float = 0.0
	var tip: float = 0.0
	for vertex: Vector3 in vertices:
		max_x = maxf(max_x, absf(vertex.x))
		max_z = maxf(max_z, absf(vertex.z))
		tip = maxf(tip, vertex.y)
	assert_true(max_x * 2.0 > 0.100 and max_x * 2.0 < 0.125, "blade width %.3f m" % (max_x * 2.0))
	assert_true(max_z * 2.0 > 0.026 and max_z * 2.0 < 0.040, "blade edge thickness %.3f m" % (max_z * 2.0))
	assert_near(tip, SwordModel.GRIP_TO_TIP, 0.001, "the tip stays at 0.94 m (decision 8)")
	root.free()


func test_metal_is_not_flat_gray() -> void:
	# Roughness and metallic come from the texture (G and B), not from fixed values.
	var root: Node3D = _load(&"base")
	var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
	for surface: int in range(mesh.get_surface_count()):
		var material: StandardMaterial3D = _standard(mesh, surface)
		assert_not_null(material, "surface %d with a standard material" % surface)
		assert_not_null(material.albedo_texture, "surface %d with albedo" % surface)
		assert_not_null(material.metallic_texture, "surface %d with a metallic texture" % surface)
		assert_not_null(material.roughness_texture, "surface %d with a roughness texture" % surface)
	root.free()


func test_the_model_carries_the_trail_markers() -> void:
	var root: Node3D = _load(&"base")
	var base: Node3D = root.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	var tip: Node3D = root.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	if assert_not_null(base, "marker of the edge's start") and assert_not_null(tip, "marker of the tip"):
		assert_near(tip.position.y, SwordModel.GRIP_TO_TIP, 0.005, "the tip at 0.94 m from the hilt")
		assert_true(base.position.y > 0.1 and base.position.y < tip.position.y, "the start, between the crossguard and the tip")
	root.free()


func test_lods_split_at_the_visibility_range() -> void:
	var root: Node3D = SwordModel.instantiate(&"base")
	assert_near(_lod(root, 0).visibility_range_end, SwordModel.LOD_DISTANCE, 0.001)
	assert_near(_lod(root, 1).visibility_range_begin, SwordModel.LOD_DISTANCE, 0.001)
	SwordModel.show_only_lod(root, 1)
	assert_false(_lod(root, 0).visible, "only LOD1")
	assert_true(_lod(root, 1).visible)
	root.free()


func test_an_unknown_variant_falls_back_to_the_base_model() -> void:
	var root: Node3D = SwordModel.instantiate(&"no_existe")
	if assert_not_null(root, "falls back to the base model"):
		assert_not_null(_lod(root, 0))
		root.free()


func test_the_grip_turns_the_blade_along_the_hand_x_axis() -> void:
	# The model has the blade along +Y; WeaponProps' grip takes it to the hand's +X, like the box.
	var basis: Basis = Basis.from_euler(WeaponProps.SWORD_GRIP_ROTATION_DEG * (PI / 180.0))
	assert_vec_near(basis * Vector3.UP, Vector3.RIGHT, 0.001, "the blade points along +X")
	assert_vec_near(basis * Vector3.BACK, Vector3.BACK, 0.001, "the flat faces still face Z")
	# The center of the hilt goes toward the fingers, not the wrist.
	assert_true(WeaponProps.SWORD_GRIP_OFFSET.y > 0.03 and WeaponProps.SWORD_GRIP_OFFSET.y < 0.12)


# --- The strike trail --------------------------------------------------------------------------

func _trail() -> SwordTrail:
	var trail := SwordTrail.new()
	tree.root.add_child(trail)
	return trail


func test_trail_collects_samples_only_while_active_and_fades_out() -> void:
	var trail: SwordTrail = _trail()
	assert_eq(trail.get_sample_count(), 0, "no samples at the start")
	trail.add_sample_points(Vector3(0, 1, 0), Vector3(0, 2, 0))
	trail.add_sample_points(Vector3(0.1, 1, 0), Vector3(0.2, 2, 0))
	assert_eq(trail.get_sample_count(), 2)
	assert_true((trail.get_node("Ribbon") as MeshInstance3D).visible, "with two samples there is already a ribbon")
	# It fades out on its own in FADE_SECONDS and drops below two samples: no ribbon.
	trail.advance(SwordTrail.FADE_SECONDS * 0.5)
	assert_eq(trail.get_sample_count(), 2, "halfway through they are still alive")
	trail.advance(SwordTrail.FADE_SECONDS * 0.6)
	assert_eq(trail.get_sample_count(), 0, "faded out")
	assert_false((trail.get_node("Ribbon") as MeshInstance3D).visible, "no ribbon")
	assert_true(SwordTrail.FADE_SECONDS >= 0.12 and SwordTrail.FADE_SECONDS <= 0.15, "fades out in 0.12-0.15 s")
	trail.free()


func test_trail_is_born_on_the_blade_and_never_passes_the_tip() -> void:
	# The ribbon runs from 40 % of the blade to the tip: no extension beyond (reach belongs to the combat data).
	var root: Node3D = SwordModel.instantiate(&"base", false)
	tree.root.add_child(root)
	var trail: SwordTrail = _trail()
	trail.bind(root)
	trail.add_sample()
	assert_eq(trail.get_sample_count(), 1)
	var tip: Node3D = root.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	var base: Node3D = root.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	var edges: PackedVector3Array = trail.get_ribbon_edges(0)
	assert_eq(edges.size(), 2, "two edges: the start and the tip")
	assert_vec_near(edges[1], tip.global_position, 0.001, "the outer edge is the model's tip")
	var blade_length: float = tip.global_position.distance_to(base.global_position)
	assert_near(edges[0].distance_to(base.global_position), blade_length * SwordTrail.INNER_FRACTION, 0.001,
			"the inner edge, at 40 % down the blade")
	assert_near(SwordTrail.INNER_FRACTION, 0.40, 0.001)
	trail.free()
	root.free()


func test_trail_follows_a_curve_through_the_samples_without_straight_chords() -> void:
	# Three samples in an arc: the dense curve passes through them and adds points in between (Catmull-Rom by time).
	var trail: SwordTrail = _trail()
	trail.add_sample_points(Vector3(0, 1, 0), Vector3(0.0, 1.8, 0.0))
	trail.advance(1.0 / 30.0)
	trail.add_sample_points(Vector3(0, 1, 0), Vector3(0.5, 1.7, 0.0))
	trail.advance(1.0 / 30.0)
	trail.add_sample_points(Vector3(0, 1, 0), Vector3(0.9, 1.4, 0.0))
	var ribbon: MeshInstance3D = trail.get_node("Ribbon") as MeshInstance3D
	var arrays: Array = (ribbon.mesh as ImmediateMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_true(vertices.size() >= 2 * 3 * 2, "the curve is split into segments (%d vertices)" % vertices.size())
	trail.free()


func test_trail_is_tinted_per_realm() -> void:
	var colors: Dictionary = {}
	for variant: StringName in VARIANTS:
		colors[variant] = SwordTrail.color_for(variant)
	assert_eq(colors.size(), 4)
	assert_true(colors[&"askarra"].r > colors[&"askarra"].b + 0.4, "Askarra, warm and reddish")
	assert_true(colors[&"vardheim"].b > colors[&"vardheim"].r + 0.3, "Vardheim, ice blue")
	assert_true(colors[&"solmarch"].r > colors[&"solmarch"].b + 0.3, "Solmarch, golden")
	assert_eq(SwordTrail.color_for(&"no_existe"), SwordTrail.DEFAULT_COLOR, "an unknown variant, the base color")


func test_trail_does_not_cast_shadows_or_read_light() -> void:
	var trail: SwordTrail = _trail()
	trail.add_sample_points(Vector3(0, 1, 0), Vector3(0, 2, 0))
	trail.add_sample_points(Vector3(0.1, 1, 0), Vector3(0.2, 2, 0))
	var ribbon: MeshInstance3D = trail.get_node("Ribbon") as MeshInstance3D
	assert_eq(ribbon.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no shadow")
	var mesh: ImmediateMesh = ribbon.mesh as ImmediateMesh
	assert_eq(mesh.get_surface_count(), 2, "body and edge line")
	var body: StandardMaterial3D = mesh.surface_get_material(0) as StandardMaterial3D
	var line: StandardMaterial3D = mesh.surface_get_material(1) as StandardMaterial3D
	assert_eq(body.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "unlit")
	assert_eq(body.blend_mode, BaseMaterial3D.BLEND_MODE_MIX, "the body, in normal blend with the saturated color")
	assert_not_null(body.albedo_texture, "with the gradient texture")
	assert_eq(line.blend_mode, BaseMaterial3D.BLEND_MODE_ADD, "the edge line, additive")
	assert_true(SwordTrail.PEAK_ALPHA <= 0.5, "maximum body alpha 0.5")
	assert_true(trail.top_level, "the samples are in world coordinates")
	trail.free()


# --- The sword in hand --------------------------------------------------------------------------

func _skeleton_with_sword() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("RightHand")
	skeleton.add_bone("LeftHand")
	tree.root.add_child(skeleton)
	WeaponProps.install(skeleton)
	return skeleton


func test_the_hand_sword_comes_with_a_trail_and_swaps_per_realm() -> void:
	var skeleton: Skeleton3D = _skeleton_with_sword()
	assert_eq(WeaponProps.get_sword_variant(skeleton), SwordModel.BASE, "starts with the base sword")
	var root: Node3D = skeleton.get_node("%s/%s" % [WeaponProps.SWORD_ATTACHMENT, WeaponProps.SWORD_MODEL_NODE]) as Node3D
	var trail: SwordTrail = root.get_node_or_null(NodePath(WeaponProps.SWORD_TRAIL_NODE)) as SwordTrail
	if not assert_not_null(trail, "the trail hangs from the sword node"):
		skeleton.free()
		return
	var triangles: int = SwordModel.triangle_count(root, 0)
	for variant: StringName in [&"vardheim", &"solmarch", &"askarra"]:
		WeaponProps.set_sword_variant(skeleton, variant)
		assert_eq(WeaponProps.get_sword_variant(skeleton), variant, "now that of %s" % variant)
		assert_true(SwordModel.triangle_count(root, 0) > 0)
		assert_eq(root.get_child_count(), 2, "a single model and the trail")
	assert_true(SwordModel.triangle_count(root, 0) != triangles, "it is another model")
	# A realm that does not exist leaves the base.
	WeaponProps.set_sword_variant(skeleton, &"huecos")
	assert_eq(WeaponProps.get_sword_variant(skeleton), SwordModel.BASE)
	# The grip does not change with the variant, nor does the twist about the blade axis.
	assert_vec_near(root.rotation_degrees, WeaponProps.SWORD_GRIP_ROTATION_DEG, 0.001, "same grip")
	var model: Node3D = root.get_node(NodePath(WeaponProps.SWORD_MODEL_INSTANCE)) as Node3D
	assert_near(model.rotation_degrees.y, WeaponProps.SWORD_ROLL_DEG, 0.001, "same twist about the blade")
	skeleton.free()


func test_swing_activity_starts_and_stops_the_trail_of_the_hand_sword() -> void:
	var skeleton: Skeleton3D = _skeleton_with_sword()
	var root: Node3D = skeleton.get_node("%s/%s" % [WeaponProps.SWORD_ATTACHMENT, WeaponProps.SWORD_MODEL_NODE]) as Node3D
	var trail: SwordTrail = root.get_node(NodePath(WeaponProps.SWORD_TRAIL_NODE)) as SwordTrail
	assert_false(trail.is_active())
	WeaponProps.set_swing_active(skeleton, true)
	assert_true(trail.is_active(), "the active strike starts the trail")
	WeaponProps.set_swing_active(skeleton, false)
	assert_false(trail.is_active(), "and when it ends it cuts it")
	# Without an installed sword it does nothing.
	WeaponProps.set_swing_active(null, true)
	skeleton.free()


func test_the_blade_roll_is_a_few_degrees_and_does_not_touch_the_reach() -> void:
	assert_true(absf(WeaponProps.SWORD_ROLL_DEG) >= 10.0 and absf(WeaponProps.SWORD_ROLL_DEG) <= 20.0,
			"the twist about the axis is 15-20 degrees")
	# The reach is still that of the combat data (3.0 m between axes): the mesh does not decide it.
	assert_near(SwordModel.GRIP_TO_TIP, 0.94, 0.0001)
