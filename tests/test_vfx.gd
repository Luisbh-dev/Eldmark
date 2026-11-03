extends TestCase
## Pruebas de los efectos de golpe (ART-09): que cada escena de [code]scenes/vfx/[/code] carga, que el
## ciclo de vida de [VfxEffect] (lanzar, acabar, volver a lanzar sin instanciar), el grupo de
## reutilización ([VfxPool]), la estela ([WeaponTrail]), el aura de carga ([ChargeAura]) y la paleta por
## reino ([VfxPalette]) hacen lo que dicen.
## [br][br]
## El visor de pruebas es headless (sin renderizador): aquí no se mira cómo se ven los efectos (eso lo
## enseñan las tiras de [code]scenes/tests/vfx_preview.tscn[/code]), sino que la mecánica es la correcta y que
## ninguna escena arrastra recursos que falten.

const EFFECT_SCENES: Dictionary = {
	"hit_metal_spark": "res://scenes/vfx/hit_metal_spark.tscn",
	"hit_flesh": "res://scenes/vfx/hit_flesh.tscn",
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
	var ring: MeshInstance3D = effect.get_node("RingWhite") as MeshInstance3D
	assert_false(ring.visible, "el anillo está oculto antes de lanzar")
	effect.play()
	_advance(effect, 0.1)
	assert_true(ring.visible, "el anillo se ve a los 0,1 s")
	var progress: Variant = ring.get_instance_shader_parameter(&"progress")
	assert_true(float(progress) > 0.1 and float(progress) < 0.9, "su avance va por el medio (%s)" % progress)
	_advance(effect, 0.5)
	assert_false(ring.visible, "el anillo se oculta al acabar su duración")


func test_delayed_shape_waits_for_its_start() -> void:
	# El segundo anillo de la parada (el dorado) empieza 0,07 s después del primero.
	var effect: VfxEffect = _spawn(load(EFFECT_SCENES["parry_flash"]) as PackedScene)
	var gold: MeshInstance3D = effect.get_node("RingGold") as MeshInstance3D
	effect.play()
	_advance(effect, 0.03)
	assert_false(gold.visible, "el anillo dorado aún no ha empezado a los 0,03 s")
	_advance(effect, 0.08)
	assert_true(gold.visible, "el anillo dorado ya se ve a los 0,11 s")


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
	var splat: MeshInstance3D = effect.get_node("Splat") as MeshInstance3D
	var red: Color = effect.tint
	var applied: Color = splat.get_instance_shader_parameter(&"tint")
	assert_near(applied.r, red.r, 0.001, "la salpicadura toma el rojo de la carne")
	assert_near(applied.g, red.g, 0.001, "...y el verde")
	# Recolorear (tela): la salpicadura sigue al tinte.
	effect.tint = Color(0.8, 0.75, 0.6)
	var cloth: Color = splat.get_instance_shader_parameter(&"tint")
	assert_near(cloth.r, 0.8, 0.001, "la tela es beige")
	assert_near(cloth.b, 0.6, 0.001, "...también en el azul")


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
	assert_true(mesh.get_aabb().size.length() > 0.5, "y la cinta abarca el arco (%s)" % mesh.get_aabb().size)
	trail.end()
	for index: int in 30:
		trail._process(STEP)
	assert_false(trail.is_active(), "se apaga sola tras max_age")
	assert_false(trail.visible, "y se oculta")
	assert_eq(mesh.get_surface_count(), 0, "sin superficies")


func test_trail_min_speed_ignores_a_slow_blade_and_breaks_between_swings() -> void:
	var trail: WeaponTrail = _spawn_trail()
	trail.min_speed = 5.0
	var target := Node3D.new()
	_spawned.append(target)
	tree.root.add_child(target)
	trail.begin(target)
	# Despacio (0,3 m/s de punta): no deja cinta.
	for index: int in 20:
		target.rotation.y = float(index) * 0.004
		trail._process(STEP)
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 0, "una hoja lenta no deja estela")
	# Rápido (la punta a 1,15 m del eje, un giro de 0,12 rad por fotograma son unos 8 m/s): sí.
	for index: int in 10:
		target.rotation.y += 0.12
		trail._process(STEP)
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 1, "una hoja rápida sí")
	trail.clear()
	assert_false(trail.is_active(), "clear la apaga de golpe")


func test_trail_colors_follow_the_realm() -> void:
	var trail: WeaponTrail = _spawn_trail()
	var seen: Dictionary[String, bool] = {}
	for realm: int in [0, NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			VfxPalette.REALM_ELDRUN]:
		trail.set_realm(realm)
		var edge: Color = trail.get_instance_shader_parameter(&"edge_color")
		seen[edge.to_html()] = true
	assert_eq(seen.size(), 5, "cada reino tiene su color de estela")


# --- Aura de carga ----------------------------------------------------------------------------

func test_charge_aura_pulses_once_at_full_charge_and_bursts_on_release() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	assert_not_null(aura, "la raíz es un ChargeAura")
	var pulse: MeshInstance3D = aura.get_node("PulseRing") as MeshInstance3D
	var burst: MeshInstance3D = aura.get_node("ReleaseRing") as MeshInstance3D
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


func test_charge_aura_scales_particles_with_charge() -> void:
	var aura: ChargeAura = _spawn(load(EFFECT_SCENES["charge_aura"]) as PackedScene) as ChargeAura
	var motes: GPUParticles3D = aura.get_node("Motes") as GPUParticles3D
	aura.play()
	aura.set_charge(0.0)
	var low: float = motes.amount_ratio
	aura.set_charge(1.0)
	assert_true(motes.amount_ratio > low, "con más carga salen más motas (%.2f -> %.2f)" % [low, motes.amount_ratio])
	assert_near(aura.get_charge(), 1.0, 0.0001, "get_charge devuelve la última carga")
	aura.stop()


func test_dust_kick_dodge_adds_the_spray_cue() -> void:
	var dust: DustKick = _spawn(load(EFFECT_SCENES["dust_kick"]) as PackedScene) as DustKick
	assert_not_null(dust, "la raíz es un DustKick")
	dust.play_landing(Vector3(2.0, 0.0, 2.0), 1.0)
	assert_vec_near(dust.global_transform.basis.z, Vector3.UP, 0.001, "el aterrizaje tiene +Z hacia arriba")
	var spray: GPUParticles3D = dust.get_node("Spray") as GPUParticles3D
	_advance(dust, 0.05)
	assert_false(spray.emitting, "el aterrizaje no levanta la estela hacia atrás")
	dust.reset()
	dust.play_dodge(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 1.0)
	assert_vec_near(dust.global_transform.basis.z, Vector3.UP, 0.001, "la esquiva también tiene +Z hacia arriba")
	assert_vec_near(dust.global_transform.basis.y, Vector3(0.0, 0.0, 1.0), 0.001,
			"y +Y hacia atrás (contrario al movimiento)")
	_advance(dust, 0.05)
	assert_true(spray.emitting, "la esquiva sí levanta la estela")


# --- Paleta -----------------------------------------------------------------------------------

func test_palette_gives_distinct_colors_per_realm() -> void:
	var realms: Array[int] = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			VfxPalette.REALM_ELDRUN]
	var trail_edges: Dictionary[String, bool] = {}
	var auras: Dictionary[String, bool] = {}
	var dusts: Dictionary[String, bool] = {}
	for realm: int in realms:
		var colors: Array[Color] = VfxPalette.trail(realm)
		assert_eq(colors.size(), 2, "la estela lleva dos colores (reino %d)" % realm)
		trail_edges[colors[1].to_html()] = true
		auras[VfxPalette.aura(realm).to_html()] = true
		dusts[VfxPalette.dust(realm).to_html()] = true
	assert_eq(trail_edges.size(), realms.size(), "estelas distintas")
	assert_eq(auras.size(), realms.size(), "auras distintas")
	assert_eq(dusts.size(), realms.size(), "polvos distintos")
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


# Avanza [param effect] [param seconds] a mano, a pasos de un fotograma (no se espera al motor: así
# la prueba no depende de que el reloj corra).
func _advance(effect: VfxEffect, seconds: float) -> void:
	var steps: int = ceili(seconds / STEP)
	for step: int in steps:
		if effect.is_playing():
			effect._process(STEP)
