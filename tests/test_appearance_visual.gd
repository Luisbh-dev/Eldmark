extends TestCase
## Appearance on the animated humanoid (docs/progresion.md §7.4 and §15, P6; ART-19): [AppearanceApplier] and
## [method HumanoidVisual.set_part]. All the combinations of pieces in the catalog (body, head, hair
## and beard, with and without) with a random color each, and 100 random appearances, applied without engine errors;
## changing one piece does not recreate the node; tints reach pieces mounted afterward; another
## player's appearance that is invalid falls back to the default of their realm.

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


# The meshes (by instance id) of each slot.
func _mesh_ids(slot: StringName) -> Array[int]:
	var ids: Array[int] = []
	for mesh: MeshInstance3D in _visual.get_part_meshes(slot):
		ids.append(mesh.get_instance_id())
	return ids


# Checks that the visual shows [param appearance]: each slot with its piece's scene (or empty) and each mesh
# with the tint of its channel.
func _check_applied(appearance: CharacterAppearance, catalog: AppearanceCatalog, label: String) -> void:
	assert_eq(_visual.get_part_path(&"body"), catalog.bodies[appearance.body].scene_path, "%s: body" % label)
	assert_eq(_visual.get_part_path(&"head"), catalog.heads[appearance.head].scene_path, "%s: head" % label)
	for pair: Array in [[&"hair", appearance.hair, catalog.hairs], [&"beard", appearance.beard, catalog.beards]]:
		var slot: StringName = pair[0]
		var value: int = pair[1]
		var parts: Array[AppearancePart] = pair[2]
		if value == CharacterAppearance.NONE:
			assert_eq(_visual.get_part_path(slot), "", "%s: without %s" % [label, slot])
			assert_true(_visual.get_part_meshes(slot).is_empty(), "%s: %s without meshes" % [label, slot])
		else:
			assert_eq(_visual.get_part_path(slot), parts[value - 1].scene_path, "%s: %s" % [label, slot])
			assert_false(_visual.get_part_meshes(slot).is_empty(), "%s: %s with meshes" % [label, slot])
	assert_eq(_visual.get_tint(&"skin"), catalog.skin_tones[appearance.skin].color, "%s: skin" % label)
	assert_eq(_visual.get_tint(&"hair"), catalog.hair_colors[appearance.hair_color].color, "%s: hair" % label)
	assert_eq(_visual.get_tint(&"eyes"), catalog.eye_colors[appearance.eyes].color, "%s: eyes" % label)
	# Each mesh with a skin, hair or eyes material carries the color of its channel.
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
				assert_null(override, "%s: %s without a tint" % [label, mesh.name])
				continue
			if not assert_not_null(override, "%s: %s tinted" % [label, mesh.name]):
				continue
			var tint: Color = _visual.get_tint(channel)
			assert_eq(override.albedo_color, tint, "%s: %s of the color of %s" % [label, mesh.name, channel])
			assert_true(override != base, "%s: the shared material is never changed" % label)
			tinted[channel] += 1
	assert_true(tinted[&"skin"] >= 2, "%s: the skin of the body and the head" % label)
	assert_true(tinted[&"eyes"] >= 1, "%s: the eyes" % label)
	assert_true(tinted[&"hair"] >= 1, "%s: at least the eyebrows" % label)


func test_every_part_combination_applies_without_engine_errors() -> void:
	if not assert_not_null(_visual, "the humanoid is installed"):
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
	# With what is in the repo: one body, one head, and hair and beard with and without.
	assert_true(combinations >= 4, "%d combinations are tested" % combinations)
	await wait_process_frames(2)


func test_one_hundred_random_appearances_per_race() -> void:
	if not assert_not_null(_visual, "the humanoid is installed"):
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
	if not assert_not_null(_visual, "the humanoid is installed"):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var visual_id: int = _visual.get_instance_id()
	var skeleton: Skeleton3D = _visual.get_skeleton()
	var skeleton_id: int = skeleton.get_instance_id()
	var animator_id: int = _visual.get_animator().get_instance_id()
	var head_ids: Array[int] = _mesh_ids(&"head")
	var body_ids: Array[int] = _mesh_ids(&"body")
	assert_false(head_ids.is_empty(), "the humanoid's head is the head slot")
	assert_false(body_ids.is_empty(), "the base model is the body slot")
	var hair_scene: PackedScene = AppearanceApplier.part_scene(catalog.hairs, 0)
	var head_scene: PackedScene = AppearanceApplier.part_scene(catalog.heads, 0)
	# The same scene changes nothing: not even a new mesh.
	_visual.set_part(&"head", head_scene)
	assert_eq(_mesh_ids(&"head"), head_ids, "the same head: the same meshes")
	_visual.set_part(&"body", AppearanceApplier.part_scene(catalog.bodies, 0))
	assert_eq(_mesh_ids(&"body"), body_ids, "the same body: the same meshes")
	# Removing and putting the hair back only touches that slot.
	_visual.clear_part(&"hair")
	assert_true(_visual.get_part_meshes(&"hair").is_empty(), "no hair")
	_visual.set_part(&"hair", hair_scene)
	assert_eq(_visual.get_part_meshes(&"hair").size(), 1, "the hairstyle comes back with its mesh")
	assert_eq(_visual.get_part_meshes(&"hair")[0].get_parent(), skeleton, "hanging from the same skeleton")
	assert_eq(_visual.get_instance_id(), visual_id, "the same HumanoidVisual")
	assert_eq(_visual.get_skeleton().get_instance_id(), skeleton_id, "the same skeleton")
	assert_eq(_visual.get_animator().get_instance_id(), animator_id, "the same animator")
	assert_eq(_mesh_ids(&"head"), head_ids, "the head has not been touched")
	assert_eq(_character.get_node(^"Visual/HumanoidVisual"), _visual, "still hanging from the character")
	# A tint set earlier applies to the piece mounted afterward.
	_visual.set_tint(&"hair", Color(0.9, 0.1, 0.1))
	_visual.clear_part(&"hair")
	_visual.set_part(&"hair", hair_scene)
	var hair: MeshInstance3D = _visual.get_part_meshes(&"hair")[0]
	var override: BaseMaterial3D = hair.get_surface_override_material(0) as BaseMaterial3D
	if assert_not_null(override, "the new hairstyle comes out tinted"):
		assert_eq(override.albedo_color, Color(0.9, 0.1, 0.1))
	# With a hood, the hairstyle mounted afterward is hidden too.
	_visual.hood_visible = true
	_visual.clear_part(&"hair")
	_visual.set_part(&"hair", hair_scene)
	assert_false(_visual.get_part_meshes(&"hair")[0].visible, "with a hood the hair is not visible")
	_visual.hood_visible = false
	assert_true(_visual.get_part_meshes(&"hair")[0].visible)
	# Removing the tints returns each mesh to its material.
	_visual.clear_tints()
	assert_null(_visual.get_part_meshes(&"hair")[0].get_surface_override_material(0), "no tint")
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
	assert_true(visual.get_part_meshes(&"beard").is_empty(), "the beard removed before entering does not appear")
	assert_false(visual.get_part_meshes(&"hair").is_empty(), "the hair does")
	assert_eq(visual.get_tint(&"skin"), catalog.skin_tones[appearance.skin].color)
	var head: MeshInstance3D = visual.get_part_meshes(&"head")[0]
	var tinted: bool = false
	for mesh: MeshInstance3D in visual.get_part_meshes(&"head"):
		for surface: int in range(mesh.mesh.get_surface_count()):
			if mesh.get_surface_override_material(surface) != null:
				tinted = true
	assert_true(tinted, "tints are applied on entering (%s)" % head.name)
	await wait_process_frames(2)


func test_resolve_falls_back_to_the_default_of_the_realm() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var vardheim: int = NetProtocol.Realm.VARDHEIM
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(vardheim))
	var default_appearance: CharacterAppearance = CharacterAppearance.default_for(catalog,
			catalog.race_index(race.id))
	# Without progress (8 B at 0), with another size or empty: the default of the realm's people.
	var zeros := PackedByteArray()
	zeros.resize(CharacterAppearance.ENCODED_SIZE)
	for bytes: PackedByteArray in [zeros, PackedByteArray(), PackedByteArray([1, 2, 3])]:
		var resolved: CharacterAppearance = AppearanceApplier.resolve(bytes, vardheim, catalog)
		assert_true(resolved != null and resolved.equals(default_appearance), "%s → default" % [bytes])
	# A valid one is left as is.
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 2
	var valid: CharacterAppearance = CharacterAppearance.random(catalog, catalog.race_index(race.id), rng)
	assert_true(AppearanceApplier.resolve(valid.encode(), vardheim, catalog).equals(valid), "a valid one is kept")
	# One from another people (valid for Solmarch) is not valid in Vardheim.
	var solmarch: int = NetProtocol.Realm.SOLMARCH
	var other_race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(solmarch))
	var other: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(other_race.id))
	assert_true(AppearanceApplier.resolve(other.encode(), vardheim, catalog).equals(default_appearance),
			"one from another realm falls back to the realm's own")
	assert_true(AppearanceApplier.resolve(other.encode(), solmarch, catalog).equals(other), "in its own realm it is valid")
	assert_null(AppearanceApplier.resolve(zeros, NetProtocol.Realm.NONE, catalog), "with no realm there is no people")
	# apply_bytes applies the resolved one.
	if assert_not_null(_visual, "the humanoid is installed"):
		var applied: CharacterAppearance = AppearanceApplier.apply_bytes(_visual, zeros, vardheim, catalog)
		assert_true(applied.equals(default_appearance))
		_check_applied(applied, catalog, "por defecto")
