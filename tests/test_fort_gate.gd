extends TestCase
## Pruebas de la puerta del fuerte (scripts/world/fort_gate.gd, docs/fuerte.md sección 3.1): las
## capas de sus dos cuerpos según el dueño y la rotura, y la pose de las hojas. Usa la escena
## suelta de la puerta (sin el Vado Gris, que tarda segundos en cargar); el comportamiento físico
## con personajes de verdad está en test_fort_gate_collision.gd.

const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const VARDHEIM_LAYER: int = 1 << 4
const SOLMARCH_LAYER: int = 1 << 5
const ASKARRA_LAYER: int = 1 << 6

var _gate: FortGate = null


func before_each() -> void:
	var scene: PackedScene = load(GATE_SCENE) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % GATE_SCENE):
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
	assert_eq(PlayerCharacter.STRUCTURE_LAYER, 8, "las estructuras van en la capa 4")
	assert_eq(PlayerCharacter.REALM_LAYER_BASE, 4)
	assert_eq(PlayerCharacter.realm_layer(1), VARDHEIM_LAYER, "Vardheim: capa 5")
	assert_eq(PlayerCharacter.realm_layer(2), SOLMARCH_LAYER, "Solmarch: capa 6")
	assert_eq(PlayerCharacter.realm_layer(3), ASKARRA_LAYER, "Askarra: capa 7")
	assert_eq(PlayerCharacter.realm_layer(0), 0, "los Huecos no tienen capa de reino")
	assert_eq(PlayerCharacter.realm_layer(4), 0, "ni un código que no es un reino")
	assert_eq(PlayerCharacter.realm_layer(-1), 0)
	# No se pisan con las capas que ya existen.
	var used: int = PlayerCharacter.WORLD_COLLISION_LAYER | PlayerCharacter.CHARACTER_COLLISION_LAYER \
			| PlayerCharacter.PLAYER_BLOCKER_LAYER | PlayerCharacter.STRUCTURE_LAYER
	for code: int in [1, 2, 3]:
		assert_eq(PlayerCharacter.realm_layer(code) & used, 0, "la capa del reino %d está libre" % code)


func test_layers_for_every_owner() -> void:
	assert_eq(FortGate.layers_for(0, false), VARDHEIM_LAYER | SOLMARCH_LAYER | ASKARRA_LAYER,
			"neutral: para a los tres reinos")
	assert_eq(FortGate.layers_for(1, false), SOLMARCH_LAYER | ASKARRA_LAYER, "de Vardheim: deja pasar a Vardheim")
	assert_eq(FortGate.layers_for(2, false), VARDHEIM_LAYER | ASKARRA_LAYER, "de Solmarch: deja pasar a Solmarch")
	assert_eq(FortGate.layers_for(3, false), VARDHEIM_LAYER | SOLMARCH_LAYER, "de Askarra: deja pasar a Askarra")
	for owner_realm: int in [0, 1, 2, 3]:
		assert_eq(FortGate.layers_for(owner_realm, true), 0, "rota (dueño %d): no para a nadie" % owner_realm)


func test_view_layer_is_structures_until_it_breaks() -> void:
	assert_eq(FortGate.view_layer_for(false), PlayerCharacter.STRUCTURE_LAYER)
	assert_eq(FortGate.view_layer_for(true), 0)


func test_the_scene_is_closed_and_neutral_by_default() -> void:
	if not assert_not_null(_gate, "la puerta debe instanciarse"):
		return
	assert_false(_gate.is_broken(), "entera")
	assert_eq(_gate.get_owner_realm(), 0, "neutral")
	assert_eq(_gate.collision_layer, FortGate.layers_for(0, false), "cuerpo de movimiento: capas 5 a 7")
	assert_eq(_gate.collision_mask, 0, "una puerta no mira a nadie")
	var view: StaticBody3D = _gate.get_view_body()
	if not assert_not_null(view, "tiene el cuerpo de vista"):
		return
	assert_eq(view.collision_layer, PlayerCharacter.STRUCTURE_LAYER, "cuerpo de vista: capa 4")
	assert_eq(view.collision_mask, 0)
	# Los dos cuerpos cierran el mismo vano.
	var closed: CollisionShape3D = _gate.get_node(^"ColisionCerrada") as CollisionShape3D
	var seen: CollisionShape3D = view.get_node(^"ColisionVista") as CollisionShape3D
	assert_false(closed.disabled)
	assert_false(seen.disabled)
	assert_eq((closed.shape as BoxShape3D).size, (seen.shape as BoxShape3D).size, "misma forma")
	assert_eq(closed.position, seen.position, "misma posición")
	assert_true(_gate.is_in_group(&"fort_gate"))
	assert_eq(_gate.get_leaf_angle(0), 0.0, "hojas cerradas")
	assert_eq(_gate.get_leaf_angle(1), 0.0)


func test_set_state_changes_the_layers_of_both_bodies() -> void:
	if not assert_not_null(_gate, "la puerta debe instanciarse"):
		return
	var view: StaticBody3D = _gate.get_view_body()
	_gate.set_state(1, false)
	assert_eq(_gate.get_owner_realm(), 1)
	assert_eq(_gate.collision_layer, SOLMARCH_LAYER | ASKARRA_LAYER, "dueño Vardheim")
	assert_eq(view.collision_layer, PlayerCharacter.STRUCTURE_LAYER, "la vista no cambia con el dueño")
	_gate.set_state(2, false)
	assert_eq(_gate.collision_layer, VARDHEIM_LAYER | ASKARRA_LAYER, "dueño Solmarch")
	_gate.set_state(2, true)
	assert_true(_gate.is_broken())
	assert_eq(_gate.collision_layer, 0, "rota: sin capas de movimiento")
	assert_eq(view.collision_layer, 0, "rota: sin capa de vista")
	_gate.set_state(2, false)
	assert_eq(_gate.collision_layer, VARDHEIM_LAYER | ASKARRA_LAYER, "reparada vuelve a cerrar")
	assert_eq(view.collision_layer, PlayerCharacter.STRUCTURE_LAYER)
	_gate.set_state(0, false)
	assert_eq(_gate.collision_layer, FortGate.layers_for(0, false), "de nuevo neutral")


func test_broken_leaves_hang_open_and_repairing_closes_them() -> void:
	if not assert_not_null(_gate, "la puerta debe instanciarse"):
		return
	var north: Node3D = _gate.get_node(^"Hoja1") as Node3D
	var closed_basis: Basis = north.basis
	assert_eq(north.position, Vector3(0.0, 0.0, -FortGate.HALF_WIDTH), "con la bisagra en el poste")
	_gate.set_state(1, true)
	assert_near(_gate.get_leaf_angle(0), -FortGate.OPEN_ANGLE, 0.0001, "la hoja norte gira hacia fuera")
	assert_near(_gate.get_leaf_angle(1), FortGate.OPEN_ANGLE, 0.0001, "la sur, al otro lado")
	assert_false(north.basis.is_equal_approx(closed_basis), "rota, la hoja norte ya no está cerrada")
	assert_eq(north.position, Vector3(0.0, 0.0, -FortGate.HALF_WIDTH), "pero sigue en la bisagra")
	_gate.set_state(1, false)
	assert_true(north.basis.is_equal_approx(closed_basis), "reparada, la hoja vuelve a su sitio")
