extends TestCase
## La apariencia sobre el humanoide animado (docs/progresion.md §7.4 y §15, P6; ART-19): [AppearanceApplier] y
## [method HumanoidVisual.set_part]. Todas las combinaciones de piezas que hay en el catálogo (cuerpo, cabeza, pelo
## y barba, con y sin) con un color al azar cada una, y 100 apariencias aleatorias, aplicadas sin errores del motor;
## cambiar una pieza no recrea el nodo; los tintes llegan a las piezas montadas después; la apariencia de otro
## jugador que no vale cae a la de por defecto de su reino.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const SEED: int = 20261030

var _world: Node3D
var _character: PlayerCharacter
var _visual: HumanoidVisual


func before_each() -> void:
	_world = Node3D.new()
	tree.root.add_child(_world)
	_character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_world.add_child(_character)
	_visual = HumanoidVisual.install_replacing_placeholder(_character)
	await wait_process_frames()


func after_each() -> void:
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	await wait_process_frames()


# Las mallas (por id de instancia) de cada ranura.
func _mesh_ids(slot: StringName) -> Array[int]:
	var ids: Array[int] = []
	for mesh: MeshInstance3D in _visual.get_part_meshes(slot):
		ids.append(mesh.get_instance_id())
	return ids


# Comprueba que el visual enseña [param appearance]: cada ranura con la escena de su pieza (o vacía) y cada malla
# con el tinte de su canal.
func _check_applied(appearance: CharacterAppearance, catalog: AppearanceCatalog, label: String) -> void:
	assert_eq(_visual.get_part_path(&"body"), catalog.bodies[appearance.body].scene_path, "%s: cuerpo" % label)
	assert_eq(_visual.get_part_path(&"head"), catalog.heads[appearance.head].scene_path, "%s: cabeza" % label)
	for pair: Array in [[&"hair", appearance.hair, catalog.hairs], [&"beard", appearance.beard, catalog.beards]]:
		var slot: StringName = pair[0]
		var value: int = pair[1]
		var parts: Array[AppearancePart] = pair[2]
		if value == CharacterAppearance.NONE:
			assert_eq(_visual.get_part_path(slot), "", "%s: sin %s" % [label, slot])
			assert_true(_visual.get_part_meshes(slot).is_empty(), "%s: %s sin mallas" % [label, slot])
		else:
			assert_eq(_visual.get_part_path(slot), parts[value - 1].scene_path, "%s: %s" % [label, slot])
			assert_false(_visual.get_part_meshes(slot).is_empty(), "%s: %s con mallas" % [label, slot])
	assert_eq(_visual.get_tint(&"skin"), catalog.skin_tones[appearance.skin].color, "%s: piel" % label)
	assert_eq(_visual.get_tint(&"hair"), catalog.hair_colors[appearance.hair_color].color, "%s: pelo" % label)
	assert_eq(_visual.get_tint(&"eyes"), catalog.eye_colors[appearance.eyes].color, "%s: ojos" % label)
	# Cada malla con material de piel, pelo u ojos lleva el color de su canal.
	var tinted: Dictionary[StringName, int] = {&"skin": 0, &"hair": 0, &"eyes": 0}
	for child: Node in _visual.get_skeleton().get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null or mesh.is_queued_for_deletion():
			continue
		for surface: int in range(mesh.mesh.get_surface_count()):
			var base: Material = mesh.mesh.surface_get_material(surface)
			var channel: StringName = HumanoidVisual._tint_channel_of(base)
			var override: BaseMaterial3D = mesh.get_surface_override_material(surface) as BaseMaterial3D
			if channel == &"":
				assert_null(override, "%s: %s sin tinte" % [label, mesh.name])
				continue
			if not assert_not_null(override, "%s: %s teñida" % [label, mesh.name]):
				continue
			var tint: Color = _visual.get_tint(channel)
			assert_eq(override.albedo_color, tint, "%s: %s del color de %s" % [label, mesh.name, channel])
			assert_true(override != base, "%s: nunca se cambia el material compartido" % label)
			tinted[channel] += 1
	assert_true(tinted[&"skin"] >= 2, "%s: la piel del cuerpo y de la cabeza" % label)
	assert_true(tinted[&"eyes"] >= 1, "%s: los ojos" % label)
	assert_true(tinted[&"hair"] >= 1, "%s: al menos las cejas" % label)


func test_every_part_combination_applies_without_engine_errors() -> void:
	if not assert_not_null(_visual, "se instala el humanoide"):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var combinations: int = 0
	for body: int in range(catalog.bodies.size()):
		for head: int in range(catalog.heads.size()):
			if not catalog.heads[head].fits_body(body):
				continue
			for hair: int in range(catalog.hairs.size() + 1):
				for beard: int in range(catalog.beards.size() + 1):
					var appearance := CharacterAppearance.new()
					appearance.race = 1
					appearance.body = body
					appearance.head = head
					appearance.hair = hair
					appearance.beard = beard
					appearance.skin = rng.randi_range(0, catalog.skin_tones.size() - 1)
					appearance.hair_color = rng.randi_range(0, catalog.hair_colors.size() - 1)
					appearance.eyes = rng.randi_range(0, catalog.eye_colors.size() - 1)
					AppearanceApplier.apply(_visual, appearance, catalog)
					_check_applied(appearance, catalog, "combinación %d" % combinations)
					combinations += 1
	# Con lo que hay en el repo: un cuerpo, una cabeza y pelo y barba con y sin.
	assert_true(combinations >= 4, "se prueban %d combinaciones" % combinations)
	await wait_process_frames(2)


func test_one_hundred_random_appearances_per_race() -> void:
	if not assert_not_null(_visual, "se instala el humanoide"):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 1
	for race_index: int in range(catalog.races.size()):
		for i: int in range(100):
			var appearance: CharacterAppearance = CharacterAppearance.random(catalog, race_index, rng)
			AppearanceApplier.apply(_visual, appearance, catalog)
			if i % 25 == 0:
				_check_applied(appearance, catalog, "%s #%d" % [catalog.races[race_index].id, i])
		await wait_process_frames()


func test_set_part_does_not_recreate_the_character() -> void:
	if not assert_not_null(_visual, "se instala el humanoide"):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var visual_id: int = _visual.get_instance_id()
	var skeleton: Skeleton3D = _visual.get_skeleton()
	var skeleton_id: int = skeleton.get_instance_id()
	var animator_id: int = _visual.get_animator().get_instance_id()
	var head_ids: Array[int] = _mesh_ids(&"head")
	var body_ids: Array[int] = _mesh_ids(&"body")
	assert_false(head_ids.is_empty(), "la cabeza del humanoide es la ranura head")
	assert_false(body_ids.is_empty(), "el modelo base es la ranura body")
	var hair_scene: PackedScene = AppearanceApplier.part_scene(catalog.hairs, 0)
	var head_scene: PackedScene = AppearanceApplier.part_scene(catalog.heads, 0)
	# La misma escena no cambia nada: ni una malla nueva.
	_visual.set_part(&"head", head_scene)
	assert_eq(_mesh_ids(&"head"), head_ids, "la misma cabeza: las mismas mallas")
	_visual.set_part(&"body", AppearanceApplier.part_scene(catalog.bodies, 0))
	assert_eq(_mesh_ids(&"body"), body_ids, "el mismo cuerpo: las mismas mallas")
	# Quitar y volver a poner el pelo solo toca esa ranura.
	_visual.clear_part(&"hair")
	assert_true(_visual.get_part_meshes(&"hair").is_empty(), "sin pelo")
	_visual.set_part(&"hair", hair_scene)
	assert_eq(_visual.get_part_meshes(&"hair").size(), 1, "el peinado vuelve con su malla")
	assert_eq(_visual.get_part_meshes(&"hair")[0].get_parent(), skeleton, "colgado del mismo esqueleto")
	assert_eq(_visual.get_instance_id(), visual_id, "el mismo HumanoidVisual")
	assert_eq(_visual.get_skeleton().get_instance_id(), skeleton_id, "el mismo esqueleto")
	assert_eq(_visual.get_animator().get_instance_id(), animator_id, "el mismo animador")
	assert_eq(_mesh_ids(&"head"), head_ids, "la cabeza no se ha tocado")
	assert_eq(_character.get_node(^"Visual/HumanoidVisual"), _visual, "sigue colgado del personaje")
	# Un tinte puesto antes vale para la pieza que se monta después.
	_visual.set_tint(&"hair", Color(0.9, 0.1, 0.1))
	_visual.clear_part(&"hair")
	_visual.set_part(&"hair", hair_scene)
	var hair: MeshInstance3D = _visual.get_part_meshes(&"hair")[0]
	var override: BaseMaterial3D = hair.get_surface_override_material(0) as BaseMaterial3D
	if assert_not_null(override, "el peinado nuevo sale teñido"):
		assert_eq(override.albedo_color, Color(0.9, 0.1, 0.1))
	# Con capucha, el peinado montado después también se oculta.
	_visual.hood_visible = true
	_visual.clear_part(&"hair")
	_visual.set_part(&"hair", hair_scene)
	assert_false(_visual.get_part_meshes(&"hair")[0].visible, "con capucha no se ve el pelo")
	_visual.hood_visible = false
	assert_true(_visual.get_part_meshes(&"hair")[0].visible)
	# Quitar los tintes devuelve cada malla a su material.
	_visual.clear_tints()
	assert_null(_visual.get_part_meshes(&"hair")[0].get_surface_override_material(0), "sin tinte")
	await wait_process_frames(2)


func test_changes_before_ready_are_kept_until_the_visual_enters_the_tree() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var scene: PackedScene = load(HumanoidVisual.SCENE_PATH) as PackedScene
	var visual: HumanoidVisual = scene.instantiate() as HumanoidVisual
	var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog, 0)
	appearance.beard = CharacterAppearance.NONE
	AppearanceApplier.apply(visual, appearance, catalog)
	var holder := Node3D.new()
	_world.add_child(holder)
	holder.add_child(visual)
	assert_true(visual.get_part_meshes(&"beard").is_empty(), "la barba quitada antes de entrar no aparece")
	assert_false(visual.get_part_meshes(&"hair").is_empty(), "el pelo sí")
	assert_eq(visual.get_tint(&"skin"), catalog.skin_tones[appearance.skin].color)
	var head: MeshInstance3D = visual.get_part_meshes(&"head")[0]
	var tinted: bool = false
	for mesh: MeshInstance3D in visual.get_part_meshes(&"head"):
		for surface: int in range(mesh.mesh.get_surface_count()):
			if mesh.get_surface_override_material(surface) != null:
				tinted = true
	assert_true(tinted, "los tintes se aplican al entrar (%s)" % head.name)
	await wait_process_frames(2)


func test_resolve_falls_back_to_the_default_of_the_realm() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var vardheim: int = NetProtocol.Realm.VARDHEIM
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(vardheim))
	var default_appearance: CharacterAppearance = CharacterAppearance.default_for(catalog,
			catalog.race_index(race.id))
	# Sin progreso (8 B a 0), con otro tamaño o vacía: la de por defecto del pueblo del reino.
	var zeros := PackedByteArray()
	zeros.resize(CharacterAppearance.ENCODED_SIZE)
	for bytes: PackedByteArray in [zeros, PackedByteArray(), PackedByteArray([1, 2, 3])]:
		var resolved: CharacterAppearance = AppearanceApplier.resolve(bytes, vardheim, catalog)
		assert_true(resolved != null and resolved.equals(default_appearance), "%s → por defecto" % [bytes])
	# Una válida se queda tal cual.
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 2
	var valid: CharacterAppearance = CharacterAppearance.random(catalog, catalog.race_index(race.id), rng)
	assert_true(AppearanceApplier.resolve(valid.encode(), vardheim, catalog).equals(valid), "una válida se queda")
	# La de otro pueblo (válida para Solmarch) no vale en Vardheim.
	var solmarch: int = NetProtocol.Realm.SOLMARCH
	var other_race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(solmarch))
	var other: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(other_race.id))
	assert_true(AppearanceApplier.resolve(other.encode(), vardheim, catalog).equals(default_appearance),
			"la de otro reino cae a la del propio")
	assert_true(AppearanceApplier.resolve(other.encode(), solmarch, catalog).equals(other), "en su reino vale")
	assert_null(AppearanceApplier.resolve(zeros, NetProtocol.Realm.NONE, catalog), "sin reino no hay pueblo")
	# apply_bytes aplica la resuelta.
	if assert_not_null(_visual, "se instala el humanoide"):
		var applied: CharacterAppearance = AppearanceApplier.apply_bytes(_visual, zeros, vardheim, catalog)
		assert_true(applied.equals(default_appearance))
		_check_applied(applied, catalog, "por defecto")
