extends TestCase
## Tests for the fort gate (scripts/world/fort_gate.gd, docs/fortress.md section 3.1): the
## layers of its two bodies according to the owner and the breakage, and the pose of the leaves. It uses the
## standalone gate scene (without Vado Gris, which takes seconds to load); the physical behavior
## with real characters is in test_fort_gate_collision.gd.

const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const VARDHEIM_LAYER: int = 1 << 4
const SOLMARCH_LAYER: int = 1 << 5
const ASKARRA_LAYER: int = 1 << 6

var _gate: FortGate = null


func before_each() -> void:
	var scene: PackedScene = load(GATE_SCENE) as PackedScene
	if not assert_not_null(scene, "%s could not be loaded" % GATE_SCENE):
		return
	_gate = scene.instantiate() as FortGate
	tree.root.add_child(_gate)
	await wait_physics_frames()


func after_each() -> void:
	if is_instance_valid(_gate):
		_gate.get_parent().remove_child(_gate)
		_gate.free()
	_gate = null


func test_the_realm_layers_are_5_to_7() -> void:
	assert_eq(PlayerCharacter.STRUCTURE_LAYER, 8, "structures go on layer 4")
	assert_eq(PlayerCharacter.REALM_LAYER_BASE, 4)
	assert_eq(PlayerCharacter.realm_layer(1), VARDHEIM_LAYER, "Vardheim: layer 5")
	assert_eq(PlayerCharacter.realm_layer(2), SOLMARCH_LAYER, "Solmarch: layer 6")
	assert_eq(PlayerCharacter.realm_layer(3), ASKARRA_LAYER, "Askarra: layer 7")
	assert_eq(PlayerCharacter.realm_layer(0), 0, "the Hollow have no realm layer")
	assert_eq(PlayerCharacter.realm_layer(4), 0, "nor does a code that is not a realm")
	assert_eq(PlayerCharacter.realm_layer(-1), 0)
	# They do not overlap with the layers that already exist.
	var used: int = PlayerCharacter.WORLD_COLLISION_LAYER | PlayerCharacter.CHARACTER_COLLISION_LAYER \
			| PlayerCharacter.PLAYER_BLOCKER_LAYER | PlayerCharacter.STRUCTURE_LAYER
	for code: int in [1, 2, 3]:
		assert_eq(PlayerCharacter.realm_layer(code) & used, 0, "the layer of realm %d is free" % code)


func test_layers_for_every_owner() -> void:
	assert_eq(FortGate.layers_for(0, false), VARDHEIM_LAYER | SOLMARCH_LAYER | ASKARRA_LAYER,
			"neutral: it stops all three realms")
	assert_eq(FortGate.layers_for(1, false), SOLMARCH_LAYER | ASKARRA_LAYER, "Vardheim's: lets Vardheim through")
	assert_eq(FortGate.layers_for(2, false), VARDHEIM_LAYER | ASKARRA_LAYER, "Solmarch's: lets Solmarch through")
	assert_eq(FortGate.layers_for(3, false), VARDHEIM_LAYER | SOLMARCH_LAYER, "Askarra's: lets Askarra through")
	for owner_realm: int in [0, 1, 2, 3]:
		assert_eq(FortGate.layers_for(owner_realm, true), 0, "broken (owner %d): it stops nobody" % owner_realm)


func test_view_layer_is_structures_until_it_breaks() -> void:
	assert_eq(FortGate.view_layer_for(false), PlayerCharacter.STRUCTURE_LAYER)
	assert_eq(FortGate.view_layer_for(true), 0)


func test_the_scene_is_closed_and_neutral_by_default() -> void:
	if not assert_not_null(_gate, "the gate must be instantiated"):
		return
	assert_false(_gate.is_broken(), "intact")
	assert_eq(_gate.get_owner_realm(), 0, "neutral")
	assert_eq(_gate.collision_layer, FortGate.layers_for(0, false), "movement body: layers 5 to 7")
	assert_eq(_gate.collision_mask, 0, "a gate faces nobody")
	var view: StaticBody3D = _gate.get_view_body()
	if not assert_not_null(view, "it has the sight body"):
		return
	assert_eq(view.collision_layer, PlayerCharacter.STRUCTURE_LAYER, "sight body: layer 4")
	assert_eq(view.collision_mask, 0)
	# The two bodies close the same doorway.
	var closed: CollisionShape3D = _gate.get_node(^"ColisionCerrada") as CollisionShape3D
	var seen: CollisionShape3D = view.get_node(^"ColisionVista") as CollisionShape3D
	assert_false(closed.disabled)
	assert_false(seen.disabled)
	assert_eq((closed.shape as BoxShape3D).size, (seen.shape as BoxShape3D).size, "same shape")
	assert_eq(closed.position, seen.position, "same position")
	assert_true(_gate.is_in_group(&"fort_gate"))
	assert_eq(_gate.get_leaf_angle(0), 0.0, "closed leaves")
	assert_eq(_gate.get_leaf_angle(1), 0.0)


func test_set_state_changes_the_layers_of_both_bodies() -> void:
	if not assert_not_null(_gate, "the gate must be instantiated"):
		return
	var view: StaticBody3D = _gate.get_view_body()
	_gate.set_state(1, false)
	assert_eq(_gate.get_owner_realm(), 1)
	assert_eq(_gate.collision_layer, SOLMARCH_LAYER | ASKARRA_LAYER, "owner Vardheim")
	assert_eq(view.collision_layer, PlayerCharacter.STRUCTURE_LAYER, "the sight does not change with the owner")
	_gate.set_state(2, false)
	assert_eq(_gate.collision_layer, VARDHEIM_LAYER | ASKARRA_LAYER, "owner Solmarch")
	_gate.set_state(2, true)
	assert_true(_gate.is_broken())
	assert_eq(_gate.collision_layer, 0, "broken: no movement layers")
	assert_eq(view.collision_layer, 0, "broken: no sight layer")
	_gate.set_state(2, false)
	assert_eq(_gate.collision_layer, VARDHEIM_LAYER | ASKARRA_LAYER, "repaired, it closes again")
	assert_eq(view.collision_layer, PlayerCharacter.STRUCTURE_LAYER)
	_gate.set_state(0, false)
	assert_eq(_gate.collision_layer, FortGate.layers_for(0, false), "neutral again")


func test_broken_leaves_hang_open_and_repairing_closes_them() -> void:
	if not assert_not_null(_gate, "the gate must be instantiated"):
		return
	var north: Node3D = _gate.get_node(^"Hoja1") as Node3D
	var closed_basis: Basis = north.basis
	assert_eq(north.position, Vector3(0.0, 0.0, -FortGate.HALF_WIDTH), "with the hinge on the post")
	_gate.set_state(1, true)
	assert_near(_gate.get_leaf_angle(0), -FortGate.OPEN_ANGLE, 0.0001, "the north leaf swings outward")
	assert_near(_gate.get_leaf_angle(1), FortGate.OPEN_ANGLE, 0.0001, "the south one, the other way")
	assert_false(north.basis.is_equal_approx(closed_basis), "broken, the north leaf is no longer closed")
	assert_eq(north.position, Vector3(0.0, 0.0, -FortGate.HALF_WIDTH), "but it stays on the hinge")
	_gate.set_state(1, false)
	assert_true(north.basis.is_equal_approx(closed_basis), "repaired, the leaf returns to its place")
