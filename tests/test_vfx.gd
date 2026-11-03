extends TestCase
## Pruebas de los efectos de golpe (ART-09): que cada escena de [code]scenes/vfx/[/code] carga, que el
## ciclo de vida de [VfxEffect] (lanzar, acabar, volver a lanzar sin instanciar), el grupo de
## reutilización ([VfxPool]), la estela ([WeaponTrail]), el aura de carga ([ChargeAura]), el polvo
## ([DustKick]) y la paleta ([VfxPalette]) hacen lo que dicen, y que los números de diseño que fijó la
## revisión de arte se cumplen (sin burbujas, tiempos y alcances máximos).
## [br][br]
## El visor de pruebas es headless (sin renderizador): aquí no se mira cómo se ven los efectos (eso lo
## enseñan las tiras de [code]scenes/tests/vfx_preview.tscn[/code]), sino que la mecánica es la correcta y que
## ninguna escena arrastra recursos que falten.

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
## Paso de tiempo con el que se avanzan los efectos a mano (60 fotogramas por segundo).
const STEP: float = 1.0 / 60.0

var _spawned: Array[Node] = []


func after_each() -> void:
	for node: Node in _spawned:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_spawned.clear()


# --- Escenas ----------------------------------------------------------------------------------

func test_every_effect_scene_loads_with_an_effect_root() -> void:
	for key: String in EFFECT_SCENES:
		var scene: PackedScene = load(EFFECT_SCENES[key]) as PackedScene
		assert_not_null(scene, "%s carga" % key)
		if scene == null:
			continue
		var effect: VfxEffect = _spawn(scene)
		assert_not_null(effect, "%s tiene un VfxEffect en la raíz" % key)
		if effect == null:
			continue
		assert_false(effect.is_playing(), "%s no suena al crearse" % key)
		assert_false(effect.visible, "%s está oculto mientras no suena" % key)


func test_trail_scene_loads_with_a_trail_root() -> void:
	var scene: PackedScene = load(TRAIL_SCENE) as PackedScene
	assert_not_null(scene, "weapon_trail carga")
	var trail: WeaponTrail = scene.instantiate() as WeaponTrail
	assert_not_null(trail, "la raíz es un WeaponTrail")
	if trail != null:
		_spawned.append(trail)
		assert_not_null(trail.material_override, "lleva el material de la estela")


func test_effects_use_only_shader_materials_that_animate_per_instance() -> void:
	# Las formas animadas por progreso comparten material entre todas las copias: el avance tiene que ser
	# un parámetro de instancia del sombreador, o cada copia pisaría a las demás.
	for key: String in EFFECT_SCENES:
		var effect: VfxEffect = _spawn(load(EFFECT_SCENES[key]) as PackedScene)
		for node: Node in effect.find_children("*", "MeshInstance3D", true, false):
			if not node.has_meta(VfxEffect.META_TIME):
				continue
			var instance: MeshInstance3D = node as MeshInstance3D
			var material: ShaderMaterial = instance.material_override as ShaderMaterial
			assert_not_null(material, "%s/%s lleva un ShaderMaterial" % [key, node.name])
			if material == null:
				continue
			assert_true(material.shader.code.contains("instance uniform float progress"),
					"%s/%s: el sombreador tiene el parámetro de instancia progress" % [key, node.name])
			var timing: Vector2 = node.get_meta(VfxEffect.META_TIME)
			assert_true(timing.y > 0.0, "%s/%s dura más de cero" % [key, node.name])


func test_every_shader_file_has_a_matching_material_use() -> void:
	# Que no sobre ningún sombreador (cada uno lo usa algún material generado) y que cada material
	# referencie uno que existe.
	var shader_files: PackedStringArray = DirAccess.get_files_at(SHADERS_DIR)
	var used: Dictionary[String, bool] = {}
	for file: String in DirAccess.get_files_at("res://scenes/vfx/materials"):
		if not file.ends_with(".tres"):
			continue
		var material: ShaderMaterial = load("res://scenes/vfx/materials/" + file) as ShaderMaterial
		assert_not_null(material, "%s carga" % file)
		if material != null and material.shader != null:
			used[material.shader.resource_path.get_file()] = true
	for file: String in shader_files:
		if file.ends_with(".gdshader"):
			assert_true(used.has(file), "%s lo usa algún material" % file)


# --- Diseño: sin burbujas, tiempos y alcances --------------------------------------------------

func test_rings_are_thin_edges_in_the_impact_plane_never_bubbles() -> void:
	# El anillo no mira a la cámara (billboard) y no tiene relleno suave: era lo que se leía como una pompa.
	for key: String in ["hit_block_wood", "parry_flash", "charge_aura"]:
		var effect: VfxEffect = _spawn(load(EFFECT_SCENES[key]) as PackedScene)
		for node: Node in effect.find_children("*", "MeshInstance3D", true, false):
			var material: ShaderMaterial = (node as MeshInstance3D).material_override as ShaderMaterial
			if material == null or material.get_shader_parameter("mode") == null 					or int(material.get_shader_parameter("mode")) != 1:
				continue
			assert_false(bool(material.get_shader_parameter("billboard")),
					"%s/%s: el anillo se orienta con la normal, no mira a la cámara" % [key, node.name])
			var fill: Variant = material.get_shader_parameter("ring_fill")
			assert_true(fill == null or float(fill) == 0.0, "%s/%s: sin relleno" % [key, node.name])


func test_parry_and_block_have_the_designed_size_and_time() -> void:
	var parry: VfxEffect = _spawn(load(EFFECT_SCENES["parry_flash"]) as PackedScene)
	assert_true(parry.duration <= 0.25, "la parada dura 0,25 s o menos (%.2f)" % parry.duration)
	var shock: MeshInstance3D = parry.get_node("Shockwave") as MeshInstance3D
	assert_true((shock.mesh as QuadMesh).size.x >= 1.2, "la onda de la parada mide 1,2 m o más")
	assert_true((shock.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.2001, "y dura 0,2 s o menos")
	assert_true(parry.has_node("Lens"), "la parada lleva el destello horizontal de lente")
	var block: VfxEffect = _spawn(load(EFFECT_SCENES["hit_block_wood"]) as PackedScene)
	var half_ring: MeshInstance3D = block.get_node("HalfRing") as MeshInstance3D
	assert_true((half_ring.mesh as QuadMesh).size.x >= 0.8, "el medio anillo del bloqueo mide 0,8 m o más")
	assert_true((half_ring.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.2001, "y dura 0,2 s o menos")
	var material: ShaderMaterial = half_ring.material_override as ShaderMaterial
	assert_true(float(material.get_shader_parameter("ring_arc")) < 0.6, "es medio anillo, no uno entero")
	assert_true(float(material.get_shader_parameter("ring_squash")) < 1.0, "y aplanado")
	# El destello del bloqueo se adelanta hacia la cámara: no lo corta el escudo.
	var flash: MeshInstance3D = block.get_node("Flash") as MeshInstance3D
	var flash_material: ShaderMaterial = flash.material_override as ShaderMaterial
	assert_true(float(flash_material.get_shader_parameter("push")) >= 0.1, "el destello se adelanta 0,1 m o más")


func test_particles_do_not_fly_further_than_designed() -> void:
	# Alcance máximo de una partícula: con frenado lineal, v*t - d*t^2/2 (o v^2 / 2d si se para antes).
	assert_true(_max_travel("hit_metal_spark", "Sparks") <= 1.8, "las chispas no pasan de 1,8 m")
	assert_true(_max_travel("hit_block_wood", "Splinters") <= 1.5, "las astillas no pasan de 1,5 m")
	assert_true(_max_travel("hit_flesh", "Drops") <= 0.45, "las gotas de sangre no pasan de 0,45 m")
	var flesh: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	assert_true(flesh.duration <= 0.4, "la carne dura 0,4 s o menos")
	var jet: MeshInstance3D = flesh.get_node("Jet") as MeshInstance3D
	var material: ShaderMaterial = jet.material_override as ShaderMaterial
	var pivot: Vector2 = material.get_shader_parameter("pivot")
	assert_true((jet.mesh as QuadMesh).size.x * 0.5 + pivot.x <= 0.41, "el chorro mide 0,4 m o menos")
	assert_true((jet.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.2001, "y dura 0,2 s o menos")


func test_flesh_jets_pick_a_variant_per_shot_and_follow_the_blow() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var jet: MeshInstance3D = effect.get_node("Jet") as MeshInstance3D
	var seen: Dictionary[String, bool] = {}
	for shot: int in 8:
		effect.play_at(Vector3.ZERO, Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0))
		seen["%s/%s" % [jet.get_instance_shader_parameter(&"variant"), jet.get_instance_shader_parameter(&"flip")]] = true
		effect.reset()
	assert_eq(seen.size(), 8, "ocho disparos seguidos dan ocho chorros distintos (4 variantes por 2 reflejos)")
	effect.play_at(Vector3.ZERO, Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0))
	assert_vec_near(effect.global_transform.basis.x, Vector3(1.0, 0.0, 0.0), 0.001, "+X sigue la dirección del golpe")
	assert_vec_near(effect.global_transform.basis.z, Vector3(0.0, 0.0, 1.0), 0.001, "+Z sigue la normal")
	assert_true(effect.global_transform.basis.is_conformal(), "sin deformar")


func test_metal_spark_cone_leans_along_the_slash() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_metal_spark"]) as PackedScene)
	var normal: Vector3 = Vector3(0.0, 0.0, 1.0)
	effect.play_at(Vector3.ZERO, normal, Vector3(-1.0, 0.0, 0.0))
	var axis: Vector3 = effect.global_transform.basis.z
	assert_true(axis.x < -0.3, "el cono se inclina hacia donde iba el tajo (%s)" % axis)
	assert_true(axis.dot(normal) > 0.5, "sin dejar de mirar hacia fuera de la superficie")
	var contact: MeshInstance3D = effect.get_node("ContactGlow") as MeshInstance3D
	assert_true((contact.get_meta(VfxEffect.META_TIME) as Vector2).y <= 0.0601, "el punto de contacto dura 0,06 s o menos")


# --- Ciclo de vida ----------------------------------------------------------------------------

func test_effect_plays_finishes_and_replays_without_new_nodes() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_metal_spark"]) as PackedScene)
	var children_before: int = effect.get_child_count()
	var finished_count: Array[int] = [0]
	effect.finished.connect(func() -> void: finished_count[0] += 1)
	for round_index: int in 3:
		effect.play()
		assert_true(effect.is_playing(), "suena tras play (vuelta %d)" % round_index)
		assert_true(effect.visible, "es visible mientras suena")
		_advance(effect, effect.duration + 0.5)
		assert_false(effect.is_playing(), "acaba solo (vuelta %d)" % round_index)
		assert_false(effect.visible, "vuelve a ocultarse")
	assert_eq(finished_count[0], 3, "emite finished una vez por vuelta")
	assert_eq(effect.get_child_count(), children_before, "reutilizar no crea nodos")


func test_shapes_run_progress_from_zero_to_one() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["parry_flash"]) as PackedScene)
	var ring: MeshInstance3D = effect.get_node("Shockwave") as MeshInstance3D
	assert_false(ring.visible, "la onda está oculta antes de lanzar")
	effect.play()
	_advance(effect, 0.07)
	assert_true(ring.visible, "la onda se ve a los 0,07 s")
	var progress: Variant = ring.get_instance_shader_parameter(&"progress")
	assert_true(float(progress) > 0.1 and float(progress) < 0.9, "su avance va por el medio (%s)" % progress)
	_advance(effect, 0.3)
	assert_false(ring.visible, "la onda se oculta al acabar su duración")


func test_delayed_shape_waits_for_its_start() -> void:
	# El chorro lateral de la carne empieza 0,04 s después del principal.
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var side: MeshInstance3D = effect.get_node("JetSide") as MeshInstance3D
	effect.play()
	_advance(effect, 0.02)
	assert_false(side.visible, "el chorro lateral aún no ha empezado a los 0,02 s")
	_advance(effect, 0.05)
	assert_true(side.visible, "el chorro lateral ya se ve a los 0,07 s")


func test_play_at_points_plus_z_along_the_normal() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var normals: Array[Vector3] = [
		Vector3.UP, Vector3(1.0, 0.0, 0.0), Vector3(0.3, 0.2, -1.0).normalized(),
		Vector3.DOWN, Vector3(0.0, 0.0, 1.0),
	]
	for normal: Vector3 in normals:
		effect.play_at(Vector3(1.0, 2.0, 3.0), normal)
		assert_vec_near(effect.global_transform.basis.z, normal, 0.001, "+Z sigue a la normal %s" % normal)
		assert_vec_near(effect.global_position, Vector3(1.0, 2.0, 3.0), 0.001, "está en el punto")
		assert_true(effect.global_transform.basis.is_conformal(), "la base no se deforma")
		effect.reset()
	# Una normal nula no rompe nada.
	effect.play_at(Vector3.ZERO, Vector3.ZERO)
	assert_true(effect.is_playing(), "con una normal nula suena igual")


func test_tint_reaches_children_by_weight() -> void:
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["hit_flesh"]) as PackedScene)
	var jet: MeshInstance3D = effect.get_node("Jet") as MeshInstance3D
	var red: Color = effect.tint
	var applied: Color = jet.get_instance_shader_parameter(&"tint")
	assert_near(applied.r, red.r, 0.001, "el chorro toma el rojo de la carne")
	assert_near(applied.g, red.g, 0.001, "...y el verde")
	# Recolorear: el chorro sigue al tinte.
	effect.tint = Color(0.8, 0.75, 0.6)
	var cloth: Color = jet.get_instance_shader_parameter(&"tint")
	assert_near(cloth.r, 0.8, 0.001, "toma el color nuevo")
	assert_near(cloth.b, 0.6, 0.001, "...también en el azul")


func test_a_disabled_part_does_not_fire_with_its_cue() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	var ring: MeshInstance3D = dust.get_node("Ring") as MeshInstance3D
	dust.play_landing(Vector3.ZERO, 0.3)
	_advance(dust, 0.1)
	assert_false(ring.visible, "una caída suave no levanta el anillo")
	dust.reset()
	dust.play_landing(Vector3.ZERO, 1.0)
	_advance(dust, 0.1)
	assert_true(ring.visible, "una caída fuerte sí")
	assert_true((ring.mesh as QuadMesh).size.x <= 1.2001, "y el anillo mide 1,2 m o menos")


# --- Grupo de reutilización -------------------------------------------------------------------

func test_pool_reuses_copies_and_never_grows() -> void:
	var pool := VfxPool.new()
	_spawned.append(pool)
	tree.root.add_child(pool)
	pool.setup(load(EFFECT_SCENES["hit_block_wood"]) as PackedScene, 3)
	assert_eq(pool.get_items().size(), 3, "crea tres copias")
	var seen: Dictionary[int, bool] = {}
	for shot: int in 10:
		var effect: VfxEffect = pool.spawn(Vector3(float(shot), 0.0, 0.0), Vector3.UP)
		assert_not_null(effect, "spawn devuelve un efecto")
		seen[effect.get_instance_id()] = true
		assert_true(pool.get_active_count() <= 3, "nunca hay más de tres sonando")
	assert_eq(seen.size(), 3, "diez disparos con tres copias: solo se ven esas tres")
	assert_eq(pool.get_child_count(), 3, "no se instancia nada nuevo")
	pool.release_all()
	assert_eq(pool.get_active_count(), 0, "release_all las apaga")


func test_pool_takes_a_free_copy_before_restarting_a_playing_one() -> void:
	var pool := VfxPool.new()
	_spawned.append(pool)
	tree.root.add_child(pool)
	pool.setup(load(EFFECT_SCENES["hit_metal_spark"]) as PackedScene, 2)
	var first: VfxEffect = pool.spawn(Vector3.ZERO)
	var second: VfxEffect = pool.spawn(Vector3.ONE)
	assert_true(first != second, "con una libre no se pisa la primera")
	_advance(first, first.duration + 0.5)
	_advance(second, second.duration + 0.5)
	assert_eq(pool.get_active_count(), 0, "al acabar quedan libres")
	var third: VfxEffect = pool.spawn(Vector3.ZERO)
	assert_not_null(third, "se puede volver a pedir")


func test_pool_keeps_the_scene_tint_unless_told_otherwise() -> void:
	var pool := VfxPool.new()
	_spawned.append(pool)
	tree.root.add_child(pool)
	var scene: PackedScene = load(EFFECT_SCENES["hit_flesh"]) as PackedScene
	var reference: VfxEffect = _spawn(scene)
	pool.setup(scene, 2)
	for item: VfxEffect in pool.get_items():
		assert_eq(item.tint, reference.tint, "el grupo no pisa el tinte de la escena (la carne es roja)")
	pool.set_tint(Color(0.5, 0.5, 0.5))
	for item: VfxEffect in pool.get_items():
		assert_eq(item.tint, Color(0.5, 0.5, 0.5), "set_tint tiñe todas las copias")


# --- Estela -----------------------------------------------------------------------------------

func test_trail_draws_a_ribbon_while_the_target_moves_and_fades_out() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	assert_false(trail.is_active(), "inactiva al crearse")
	trail.begin(target)
	# La hoja barre un arco de medio giro en 0,25 s.
	for index: int in 15:
		target.rotation.y = float(index) / 15.0 * PI
		trail._process(STEP)
	assert_true(trail.is_active(), "activa mientras sigue al arma")
	assert_true(trail.visible, "visible")
	var mesh: ImmediateMesh = trail.mesh as ImmediateMesh
	assert_eq(mesh.get_surface_count(), 1, "una superficie con la cinta")
	assert_true(mesh.get_aabb().size.length() > 0.3, "y la cinta abarca el arco (%s)" % mesh.get_aabb().size)
	trail.end()
	for index: int in 30:
		trail._process(STEP)
	assert_false(trail.is_active(), "se apaga sola tras max_age")
	assert_false(trail.visible, "y se oculta")
	assert_eq(mesh.get_surface_count(), 0, "sin superficies")


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
	assert_eq(mesh.get_surface_count(), 0, "con dos muestras no se dibuja nada (sería un cuadrilátero recto)")
	target.rotation.y = 0.3
	trail._process(STEP)
	assert_eq(mesh.get_surface_count(), 1, "con tres sí")
	assert_eq(trail.min_samples, 3, "el mínimo es tres")
	assert_true(trail.max_age <= 0.12, "la cola dura 0,12 s o menos")


func test_trail_min_speed_ignores_a_slow_blade_and_breaks_between_swings() -> void:
	var trail: WeaponTrail = _spawn_trail()
	trail.min_speed = 5.0
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	# Despacio (0,2 m/s de punta): no deja cinta.
	for index: int in 20:
		target.rotation.y = float(index) * 0.004
		trail._process(STEP)
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 0, "una hoja lenta no deja estela")
	# Rápido (la punta a 0,9 m del eje, un giro de 0,12 rad por fotograma son unos 6,5 m/s): sí.
	for index: int in 10:
		target.rotation.y += 0.12
		trail._process(STEP)
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 1, "una hoja rápida sí")
	trail.clear()
	assert_false(trail.is_active(), "clear la apaga de golpe")


func test_trail_cuts_at_a_pose_jump_and_caps_its_length() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	for index: int in 6:
		target.rotation.y = float(index) * 0.2
		trail._process(STEP)
	assert_true(trail._times.size() >= 3, "hay cinta antes del salto")
	# Un salto de pose de varios metros en un fotograma no es un tajo: corta la cinta, no tiende un cable.
	target.position = Vector3(8.0, 0.0, 0.0)
	trail._process(STEP)
	assert_true(trail._times.size() < 3, "tras el salto no queda cinta unida a la anterior")
	# Un arco muy largo se recorta por la parte vieja.
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
	assert_true(length <= 0.5 + 0.35, "el arco que se dibuja no pasa de max_length (%.2f)" % length)


func test_trail_axial_motion_is_marked_as_not_lateral() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	# Una estocada: la hoja (eje X) avanza a lo largo de su propio eje.
	for index: int in 5:
		target.position = Vector3(float(index) * 0.15, 0.0, 0.0)
		trail._process(STEP)
	assert_true(trail._lateral.size() >= 3, "hay muestras")
	assert_true(trail._lateral[trail._lateral.size() - 1] < 0.1, "el movimiento axial no pinta ancho")


func test_trail_colors_follow_the_realm() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var seen: Dictionary[String, bool] = {}
	for realm: int in [0, NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			VfxPalette.REALM_ELDRUN]:
		trail.set_realm(realm)
		var edge: Color = trail.get_instance_shader_parameter(&"edge_color")
		seen[edge.to_html()] = true
	assert_eq(seen.size(), 5, "cada reino tiene su color de estela")
	var vardheim: Color = VfxPalette.trail(NetProtocol.Realm.VARDHEIM)[1]
	assert_true(vardheim.b > 0.95 and vardheim.g > 0.7 and vardheim.r > 0.4 and vardheim.r < 0.6,
			"Vardheim es azul hielo (%s), no cobalto" % vardheim)


# --- Aura de carga ----------------------------------------------------------------------------

func test_charge_aura_pulses_once_at_full_charge_and_bursts_on_release() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	assert_not_null(aura, "la raíz es un ChargeAura")
	var pulse: MeshInstance3D = aura.get_node("PulseWave") as MeshInstance3D
	var burst: MeshInstance3D = aura.get_node("ReleaseWave") as MeshInstance3D
	aura.play()
	aura.set_charge(0.4)
	_advance(aura, 0.3)
	assert_true(aura.is_playing(), "el aura sigue (es continua)")
	assert_false(pulse.visible, "sin carga completa no hay pulso")
	aura.set_charge(1.0)
	_advance(aura, 0.1)
	assert_true(pulse.visible, "con la carga completa suena el pulso")
	_advance(aura, 0.6)
	assert_false(pulse.visible, "el pulso acaba")
	aura.set_charge(1.0)
	_advance(aura, 0.1)
	assert_false(pulse.visible, "y no se repite mientras sigue completa")
	aura.release()
	_advance(aura, 0.1)
	assert_true(burst.visible, "al soltar hay estallido")
	_advance(aura, 3.0)
	assert_false(aura.is_playing(), "tras soltar se apaga del todo")


func test_charge_aura_is_in_the_weapon_not_a_shell_around_the_body() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	assert_false(aura.has_node("Shell"), "no hay cáscara de hebras sobre el cuerpo")
	assert_true(aura.has_node("Blade/BladeGlow"), "el brillo va en la hoja")
	assert_true(aura.has_node("Blade/Motes"), "las motas se absorben en la hoja")
	assert_true(aura.has_node("Rune"), "y queda la runa del suelo")
	# Con arma, todo lo de la hoja cuelga de ella y la sigue.
	var weapon := Node3D.new()
	_spawned.append(weapon)
	tree.root.add_child(weapon)
	aura.set_weapon(weapon)
	assert_false(aura.has_node("Blade"), "la hoja ya no cuelga del personaje")
	assert_not_null(weapon.get_node_or_null("Blade/BladeGlow"), "cuelga del arma")
	aura.play()
	aura.set_charge(0.7)
	var glow: MeshInstance3D = weapon.get_node("Blade/BladeGlow") as MeshInstance3D
	assert_near(float(glow.get_instance_shader_parameter(&"charge")), 0.7, 0.001, "el brillo de la hoja crece con la carga")
	assert_true(weapon.get_node("Blade").visible, "la hoja se ve mientras suena")
	aura.stop()
	_advance(aura, 3.0)
	assert_false(weapon.get_node("Blade").visible, "y se oculta al apagarse")


func test_charge_aura_scales_particles_with_charge() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	var motes: GPUParticles3D = aura.get_node("Blade/Motes") as GPUParticles3D
	aura.play()
	aura.set_charge(0.0)
	var low: float = motes.amount_ratio
	aura.set_charge(1.0)
	assert_true(motes.amount_ratio > low, "con más carga salen más motas (%.2f -> %.2f)" % [low, motes.amount_ratio])
	assert_near(aura.get_charge(), 1.0, 0.0001, "get_charge devuelve la última carga")
	aura.stop()


# --- Polvo ------------------------------------------------------------------------------------

func test_dust_kick_landing_and_dodge_are_different_shapes() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	assert_not_null(dust, "la raíz es un DustKick")
	var spray: GPUParticles3D = dust.get_node("Spray") as GPUParticles3D
	var puffs: GPUParticles3D = dust.get_node("Puffs") as GPUParticles3D
	var crescent: MeshInstance3D = dust.get_node("Crescent") as MeshInstance3D
	dust.play_landing(Vector3(2.0, 0.0, 2.0), 1.0)
	assert_vec_near(dust.global_transform.basis.z, Vector3.UP, 0.001, "el aterrizaje tiene +Z hacia arriba")
	_advance(dust, 0.05)
	assert_true(puffs.emitting, "el aterrizaje abre las bocanadas en anillo")
	assert_false(spray.emitting, "y no levanta la rociada hacia atrás")
	assert_false(crescent.visible, "ni la media luna")
	dust.reset()
	dust.play_dodge(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 1.0)
	assert_vec_near(dust.global_transform.basis.z, Vector3.UP, 0.001, "la esquiva también tiene +Z hacia arriba")
	assert_vec_near(dust.global_transform.basis.y, Vector3(0.0, 0.0, 1.0), 0.001,
			"y +Y hacia atrás (contrario al movimiento)")
	_advance(dust, 0.05)
	assert_true(spray.emitting, "la esquiva sí levanta la rociada")
	assert_true(crescent.visible, "y la media luna")
	assert_false(puffs.emitting, "pero no el anillo de bocanadas del aterrizaje")


func test_dust_color_comes_from_the_ground_not_the_realm() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	assert_false("realm" in dust, "el polvo no tiene reino")
	dust.set_ground(&"sand")
	assert_eq(dust.tint, VfxPalette.ground(&"sand"), "el color es el del material del suelo")
	dust.set_ground_color(Color(0.3, 0.4, 0.5))
	assert_eq(dust.tint, Color(0.3, 0.4, 0.5), "o el que se lee del terreno")
	assert_eq(VfxGround.color_at(null, Vector3.ZERO, &"stone"), VfxPalette.ground(&"stone"),
			"sin terreno cae al material de reserva")
	var seen: Dictionary[String, bool] = {}
	for kind: StringName in VfxPalette.GROUND_KINDS:
		seen[VfxPalette.ground(kind).to_html()] = true
	assert_eq(seen.size(), VfxPalette.GROUND_KINDS.size(), "cada material de suelo tiene su color")


# --- Paleta -----------------------------------------------------------------------------------

func test_palette_gives_distinct_colors_per_realm() -> void:
	var realms: Array[int] = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			VfxPalette.REALM_ELDRUN]
	var trail_edges: Dictionary[String, bool] = {}
	var auras: Dictionary[String, bool] = {}
	for realm: int in realms:
		var colors: Array[Color] = VfxPalette.trail(realm)
		assert_eq(colors.size(), 2, "la estela lleva dos colores (reino %d)" % realm)
		trail_edges[colors[1].to_html()] = true
		auras[VfxPalette.aura(realm).to_html()] = true
	assert_eq(trail_edges.size(), realms.size(), "estelas distintas")
	assert_eq(auras.size(), realms.size(), "auras distintas")
	# El reino desconocido cae en el neutro y no rompe.
	assert_eq(VfxPalette.trail(99).size(), 2, "un reino desconocido tiene colores neutros")


# --- Ayudantes --------------------------------------------------------------------------------

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


# Alcance máximo (m) de las partículas [param node_name] de la escena [param key]: la velocidad inicial máxima
# con el frenado mínimo, durante su vida (sin contar la gravedad, que las baja).
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


# Avanza [param effect] [param seconds] a mano, a pasos de un fotograma (no se espera al motor: así
# la prueba no depende de que el reloj corra).
func _advance(effect: VfxEffect, seconds: float) -> void:
	var steps: int = ceili(seconds / STEP)
	for step: int in steps:
		if effect.is_playing():
			effect._process(STEP)
