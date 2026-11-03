extends TestCase
## El modelo propio de la espada (tools/blender/build_sword.py, scripts/client/sword_model.gd): los
## cuatro GLB cargan con sus dos LOD, miden lo que deben, comparten exactamente la misma hoja y solo
## cambian guarda, pomo y colores.

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
		if not assert_not_null(root, "carga el modelo %s" % variant):
			continue
		var near: MeshInstance3D = _lod(root, 0)
		var far: MeshInstance3D = _lod(root, 1)
		assert_not_null(near, "%s: malla de detalle completo" % variant)
		assert_not_null(far, "%s: malla de detalle sencillo" % variant)
		if near == null or far == null:
			root.free()
			continue
		var near_tris: int = SwordModel.triangle_count(root, 0)
		var far_tris: int = SwordModel.triangle_count(root, 1)
		assert_true(near_tris >= 1500 and near_tris <= 4500,
				"%s: el LOD0 tiene entre 1.500 y 4.500 triángulos (%d)" % [variant, near_tris])
		assert_true(far_tris > 0 and far_tris < near_tris * 0.35,
				"%s: el LOD1 pesa menos de un tercio del LOD0 (%d de %d)" % [variant, far_tris, near_tris])
		root.free()


func test_the_sword_is_about_1_1_m_long_with_the_grip_at_the_origin() -> void:
	for variant: StringName in VARIANTS:
		var root: Node3D = _load(variant)
		if not assert_not_null(root):
			continue
		var box: AABB = _lod(root, 0).mesh.get_aabb()
		assert_true(box.size.y > 1.05 and box.size.y < 1.2,
				"%s: mide %.3f m de largo" % [variant, box.size.y])
		# La punta a 0,94 m del centro de la empuñadura; el pomo, por detrás.
		assert_near(box.end.y, SwordModel.GRIP_TO_TIP, 0.01, "%s: la punta" % variant)
		assert_true(box.position.y < -0.14 and box.position.y > -0.25,
				"%s: el pomo queda detrás de la mano (%.3f)" % [variant, box.position.y])
		assert_true(box.size.x > 0.30 and box.size.x < 0.45, "%s: la guarda abarca %.2f m" % [variant, box.size.x])
		# Grosor total: lo más grueso es el pomo redondo del base (7 cm); el resto es plano por Z.
		assert_true(box.size.z < 0.09, "%s: grosor %.3f m" % [variant, box.size.z])
		root.free()


func test_every_variant_shares_the_same_blade() -> void:
	var base: Node3D = _load(&"base")
	var base_mesh: ArrayMesh = _lod(base, 0).mesh as ArrayMesh
	var base_arrays: Array = base_mesh.surface_get_arrays(0)
	assert_eq(_standard(base_mesh, 0).resource_name, "SwordBlade", "la superficie 0 es la hoja")
	var base_albedo: Image = _standard(base_mesh, 0).albedo_texture.get_image()
	for variant: StringName in [&"vardheim", &"solmarch", &"askarra"]:
		var other: Node3D = _load(variant)
		var mesh: ArrayMesh = _lod(other, 0).mesh as ArrayMesh
		assert_eq(_standard(mesh, 0).resource_name, "SwordBlade", "%s: la superficie 0 es la hoja" % variant)
		var arrays: Array = mesh.surface_get_arrays(0)
		assert_true(arrays[Mesh.ARRAY_VERTEX] == base_arrays[Mesh.ARRAY_VERTEX],
				"%s: mismos vértices de la hoja que el base" % variant)
		assert_true(arrays[Mesh.ARRAY_TEX_UV] == base_arrays[Mesh.ARRAY_TEX_UV],
				"%s: mismas UV de la hoja" % variant)
		var albedo: Image = _standard(mesh, 0).albedo_texture.get_image()
		assert_eq(albedo.get_size(), base_albedo.get_size(), "%s: mismo tamaño de textura" % variant)
		assert_true(albedo.get_data() == base_albedo.get_data(), "%s: misma textura de la hoja" % variant)
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
		assert_true(SwordModel.triangle_count(other, 0) != base_tris, "%s: otra guarda y otro pomo" % variant)
		assert_false(_standard(mesh, 1).albedo_texture.get_image().get_data() == base_leather.get_data(),
				"%s: otro cuero" % variant)
		assert_false(_standard(mesh, 2).albedo_texture.get_image().get_data() == base_metal.get_data(),
				"%s: otro metal" % variant)
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
		assert_eq(emissive, variant == &"askarra", "%s: brasa emisiva solo en Askarra" % variant)
		root.free()


func test_metal_is_not_flat_gray() -> void:
	# Roughness y metálico vienen de la textura (G y B), no de valores fijos.
	var root: Node3D = _load(&"base")
	var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
	for surface: int in range(mesh.get_surface_count()):
		var material: StandardMaterial3D = _standard(mesh, surface)
		assert_not_null(material, "superficie %d con material estándar" % surface)
		assert_not_null(material.albedo_texture, "superficie %d con albedo" % surface)
		assert_not_null(material.metallic_texture, "superficie %d con textura de metálico" % surface)
		assert_not_null(material.roughness_texture, "superficie %d con textura de rugosidad" % surface)
	root.free()


func test_the_model_carries_the_trail_markers() -> void:
	var root: Node3D = _load(&"base")
	var base: Node3D = root.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	var tip: Node3D = root.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	if assert_not_null(base, "marca del arranque del filo") and assert_not_null(tip, "marca de la punta"):
		assert_near(tip.position.y, SwordModel.GRIP_TO_TIP, 0.005, "la punta a 0,94 m de la empuñadura")
		assert_true(base.position.y > 0.1 and base.position.y < tip.position.y, "el arranque, entre la guarda y la punta")
	root.free()


func test_lods_split_at_the_visibility_range() -> void:
	var root: Node3D = SwordModel.instantiate(&"base")
	assert_near(_lod(root, 0).visibility_range_end, SwordModel.LOD_DISTANCE, 0.001)
	assert_near(_lod(root, 1).visibility_range_begin, SwordModel.LOD_DISTANCE, 0.001)
	SwordModel.show_only_lod(root, 1)
	assert_false(_lod(root, 0).visible, "solo el LOD1")
	assert_true(_lod(root, 1).visible)
	root.free()


func test_an_unknown_variant_falls_back_to_the_base_model() -> void:
	var root: Node3D = SwordModel.instantiate(&"no_existe")
	if assert_not_null(root, "cae al modelo base"):
		assert_not_null(_lod(root, 0))
		root.free()


func test_the_grip_turns_the_blade_along_the_hand_x_axis() -> void:
	# El modelo tiene la hoja por +Y; el agarre de WeaponProps la lleva a +X de la mano, como la caja.
	var basis: Basis = Basis.from_euler(WeaponProps.SWORD_GRIP_ROTATION_DEG * (PI / 180.0))
	assert_vec_near(basis * Vector3.UP, Vector3.RIGHT, 0.001, "la hoja sale por +X")
	assert_vec_near(basis * Vector3.BACK, Vector3.BACK, 0.001, "las caras planas siguen mirando a Z")
	# El centro de la empuñadura va hacia los dedos, no a la muñeca.
	assert_true(WeaponProps.SWORD_GRIP_OFFSET.y > 0.03 and WeaponProps.SWORD_GRIP_OFFSET.y < 0.12)
