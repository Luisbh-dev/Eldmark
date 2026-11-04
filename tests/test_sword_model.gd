extends TestCase
## El modelo propio de la espada (tools/blender/build_sword.py, scripts/client/sword_model.gd): los
## cuatro GLB cargan con sus dos LOD, miden lo que deben, comparten exactamente la misma geometría y las
## mismas UV de la hoja (cada reino le pone su propia textura: acanaladura de hielo, de oro o de brasa) y
## solo cambian guarda, pomo y colores. También la estela del golpe ([SwordTrail]) y la espada por reino de
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


func test_every_variant_shares_the_same_blade_geometry() -> void:
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
		# La geometría y las UV son las mismas; la textura no: cada reino se ve en la hoja.
		var albedo: Image = _standard(mesh, 0).albedo_texture.get_image()
		assert_eq(albedo.get_size(), base_albedo.get_size(), "%s: mismo tamaño de textura" % variant)
		assert_false(albedo.get_data() == base_albedo.get_data(), "%s: su propia textura de hoja" % variant)
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


func test_askarra_blade_carries_the_glowing_crack_and_the_others_do_not() -> void:
	# La grieta en llamas va en la acanaladura de la hoja (textura de emisión), no solo en el pomo.
	for variant: StringName in VARIANTS:
		var root: Node3D = _load(variant)
		var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
		var blade: StandardMaterial3D = _standard(mesh, 0)
		if variant == &"askarra":
			assert_true(blade.emission_enabled, "la hoja de Askarra emite")
			assert_not_null(blade.emission_texture, "con la grieta como textura de emisión")
			assert_true(blade.emission_energy_multiplier >= 3.0 and blade.emission_energy_multiplier <= 4.0,
					"con fuerza de 3 a 4 (%.1f)" % blade.emission_energy_multiplier)
		else:
			assert_false(blade.emission_enabled, "%s: la hoja no emite" % variant)
		root.free()


func test_blade_is_dark_with_a_bright_thin_edge() -> void:
	# El contraste sale de un albedo oscuro con el filo claro (un acero claro se funde con el cielo gris).
	var root: Node3D = _load(&"base")
	var mesh: ArrayMesh = _lod(root, 0).mesh as ArrayMesh
	var image: Image = _standard(mesh, 0).albedo_texture.get_image()
	image.decompress()
	var w: int = image.get_width()
	var h: int = image.get_height()
	var row: int = int(h * 0.5)
	# La cara plana (a un 40 % del medio ancho) es oscura y el filo (al 96 %) es claro.
	var face: Color = image.get_pixel(int(w * (0.5 + 0.5 * 0.40)), row)
	var edge: Color = image.get_pixel(int(w * (0.5 + 0.5 * 0.96)), row)
	assert_true(face.get_luminance() > 0.20 and face.get_luminance() < 0.55,
			"la cara plana es de acero oscuro (%.2f)" % face.get_luminance())
	assert_true(edge.get_luminance() > 0.85, "el filo es claro (%.2f)" % edge.get_luminance())
	# Más oscura junto a la guarda que hacia la punta.
	# (La fila 0 de la imagen es la punta: v = 1.)
	var near_guard: Color = image.get_pixel(int(w * 0.70), int(h * 0.75))
	var near_tip: Color = image.get_pixel(int(w * 0.70), int(h * 0.12))
	assert_true(near_guard.get_luminance() < near_tip.get_luminance(), "degradado a lo largo")
	root.free()


func test_blade_has_heroic_proportions() -> void:
	# Más ancha y gruesa que una espada real (8,9 x 1,4 cm), con la punta donde estaba.
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
	assert_true(max_x * 2.0 > 0.100 and max_x * 2.0 < 0.125, "ancho de hoja %.3f m" % (max_x * 2.0))
	assert_true(max_z * 2.0 > 0.026 and max_z * 2.0 < 0.040, "canto de hoja %.3f m" % (max_z * 2.0))
	assert_near(tip, SwordModel.GRIP_TO_TIP, 0.001, "la punta sigue a 0,94 m (decisión 8)")
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


# --- La estela del golpe -----------------------------------------------------------------------

func _trail() -> SwordTrail:
	var trail := SwordTrail.new()
	tree.root.add_child(trail)
	return trail


func test_trail_collects_samples_only_while_active_and_fades_out() -> void:
	var trail: SwordTrail = _trail()
	assert_eq(trail.get_sample_count(), 0, "sin muestras al empezar")
	trail.add_sample_points(Vector3(0, 1, 0), Vector3(0, 2, 0))
	trail.add_sample_points(Vector3(0.1, 1, 0), Vector3(0.2, 2, 0))
	assert_eq(trail.get_sample_count(), 2)
	assert_true((trail.get_node("Ribbon") as MeshInstance3D).visible, "con dos muestras ya hay cinta")
	# Se apaga sola en FADE_SECONDS y cae por debajo de dos muestras: sin cinta.
	trail.advance(SwordTrail.FADE_SECONDS * 0.5)
	assert_eq(trail.get_sample_count(), 2, "a medio camino siguen vivas")
	trail.advance(SwordTrail.FADE_SECONDS * 0.6)
	assert_eq(trail.get_sample_count(), 0, "apagadas")
	assert_false((trail.get_node("Ribbon") as MeshInstance3D).visible, "sin cinta")
	assert_true(SwordTrail.FADE_SECONDS >= 0.12 and SwordTrail.FADE_SECONDS <= 0.15, "se apaga en 0,12-0,15 s")
	trail.free()


func test_trail_reaches_out_to_about_2_2_m_along_the_blade() -> void:
	# La estela alarga el borde exterior más allá de la punta para enseñar el alcance (decisión 8).
	var root: Node3D = SwordModel.instantiate(&"base", false)
	tree.root.add_child(root)
	var trail: SwordTrail = _trail()
	trail.bind(root)
	trail.add_sample()
	assert_eq(trail.get_sample_count(), 1)
	var tip: Node3D = root.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	var base: Node3D = root.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	var edges: PackedVector3Array = trail.get_edges(0)
	var outer: Vector3 = edges[edges.size() - 1]
	assert_vec_near(edges[edges.size() - 2], tip.global_position, 0.001, "la línea del núcleo es la punta del modelo")
	assert_true(edges[0].distance_to(base.global_position) < tip.global_position.distance_to(base.global_position),
			"el borde interior queda dentro del filo")
	assert_near(outer.distance_to(base.global_position),
			tip.global_position.distance_to(base.global_position) + SwordTrail.REACH_EXTENSION, 0.01,
			"el borde exterior sale de la punta siguiendo la hoja")
	# Desde el eje del personaje (la mano está a medio metro) llega a unos 2,2 m con el agarre real.
	var from_grip: float = outer.distance_to(root.global_position)
	assert_true(from_grip + 0.55 > 2.0 and from_grip + 0.55 < 2.4, "alcance dibujado: %.2f m" % (from_grip + 0.55))
	trail.free()
	root.free()


func test_trail_is_tinted_per_realm() -> void:
	var colors: Dictionary = {}
	for variant: StringName in VARIANTS:
		colors[variant] = SwordTrail.color_for(variant)
	assert_eq(colors.size(), 4)
	assert_true(colors[&"askarra"].r > colors[&"askarra"].b + 0.4, "Askarra, cálida y rojiza")
	assert_true(colors[&"vardheim"].b > colors[&"vardheim"].r + 0.3, "Vardheim, azul hielo")
	assert_true(colors[&"solmarch"].r > colors[&"solmarch"].b + 0.3, "Solmarch, dorada")
	assert_eq(SwordTrail.color_for(&"no_existe"), SwordTrail.DEFAULT_COLOR, "una variante desconocida, el color base")


func test_trail_does_not_cast_shadows_or_read_light() -> void:
	var trail: SwordTrail = _trail()
	var ribbon: MeshInstance3D = trail.get_node("Ribbon") as MeshInstance3D
	assert_eq(ribbon.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "sin sombra")
	var material: StandardMaterial3D = ribbon.material_override as StandardMaterial3D
	assert_eq(material.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "sin luz")
	assert_eq(material.blend_mode, BaseMaterial3D.BLEND_MODE_ADD, "aditiva")
	assert_true(trail.top_level, "las muestras están en coordenadas del mundo")
	trail.free()


# --- La espada de la mano -----------------------------------------------------------------------

func _skeleton_with_sword() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("RightHand")
	skeleton.add_bone("LeftHand")
	tree.root.add_child(skeleton)
	WeaponProps.install(skeleton)
	return skeleton


func test_the_hand_sword_comes_with_a_trail_and_swaps_per_realm() -> void:
	var skeleton: Skeleton3D = _skeleton_with_sword()
	assert_eq(WeaponProps.get_sword_variant(skeleton), SwordModel.BASE, "empieza con la espada base")
	var root: Node3D = skeleton.get_node("%s/%s" % [WeaponProps.SWORD_ATTACHMENT, WeaponProps.SWORD_MODEL_NODE]) as Node3D
	var trail: SwordTrail = root.get_node_or_null(NodePath(WeaponProps.SWORD_TRAIL_NODE)) as SwordTrail
	if not assert_not_null(trail, "la estela cuelga del nodo de la espada"):
		skeleton.free()
		return
	var triangles: int = SwordModel.triangle_count(root, 0)
	for variant: StringName in [&"vardheim", &"solmarch", &"askarra"]:
		WeaponProps.set_sword_variant(skeleton, variant)
		assert_eq(WeaponProps.get_sword_variant(skeleton), variant, "ahora la de %s" % variant)
		assert_true(SwordModel.triangle_count(root, 0) > 0)
		assert_eq(root.get_child_count(), 2, "un solo modelo y la estela")
	assert_true(SwordModel.triangle_count(root, 0) != triangles, "es otro modelo")
	# Un reino que no existe deja la base.
	WeaponProps.set_sword_variant(skeleton, &"huecos")
	assert_eq(WeaponProps.get_sword_variant(skeleton), SwordModel.BASE)
	# El agarre no cambia con la variante, ni el giro sobre el eje de la hoja.
	assert_vec_near(root.rotation_degrees, WeaponProps.SWORD_GRIP_ROTATION_DEG, 0.001, "mismo agarre")
	var model: Node3D = root.get_node(NodePath(WeaponProps.SWORD_MODEL_INSTANCE)) as Node3D
	assert_near(model.rotation_degrees.y, WeaponProps.SWORD_ROLL_DEG, 0.001, "mismo giro sobre la hoja")
	skeleton.free()


func test_swing_activity_starts_and_stops_the_trail_of_the_hand_sword() -> void:
	var skeleton: Skeleton3D = _skeleton_with_sword()
	var root: Node3D = skeleton.get_node("%s/%s" % [WeaponProps.SWORD_ATTACHMENT, WeaponProps.SWORD_MODEL_NODE]) as Node3D
	var trail: SwordTrail = root.get_node(NodePath(WeaponProps.SWORD_TRAIL_NODE)) as SwordTrail
	assert_false(trail.is_active())
	WeaponProps.set_swing_active(skeleton, true)
	assert_true(trail.is_active(), "el golpe activo lanza la estela")
	WeaponProps.set_swing_active(skeleton, false)
	assert_false(trail.is_active(), "y al acabar la corta")
	# Sin espada instalada no hace nada.
	WeaponProps.set_swing_active(null, true)
	skeleton.free()


func test_the_blade_roll_is_a_few_degrees_and_does_not_touch_the_reach() -> void:
	assert_true(absf(WeaponProps.SWORD_ROLL_DEG) >= 10.0 and absf(WeaponProps.SWORD_ROLL_DEG) <= 20.0,
			"el giro sobre el eje es de 15-20 grados")
	# El alcance sigue siendo el de los datos de combate (3,0 m entre ejes): la malla no lo decide.
	assert_near(SwordModel.GRIP_TO_TIP, 0.94, 0.0001)
