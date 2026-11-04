@tool
class_name FortGate
extends StaticBody3D
## Wooden gate of the Vado Gris fort (group [code]fort_gate[/code]). Shared scene: client and
## server load it the same way, and it does not depend on anything in [code]scripts/client/[/code].
##
## Two plank leaves hinged on the opening's posts. It is stored [b]closed[/b] and only breakage
## (health 0) opens it: then the leaves hang outward, toward the esplanade, so as not to collide
## with the walkway that passes over the opening on the inside.
## [br][br]
## [b]Two bodies[/b] (docs/fuerte.md, section 3.1). Taking the gate off the world layer would break
## the line of sight of hits, the camera and the navigation bake, so:
## [br]- the node itself is the [b]movement[/b] body: its layer is realm layers 5 to 7 of the
## realms that are [b]not[/b] the owner ([method layers_for]). Each character adds its realm's
## layer to its mask ([method PlayerCharacter.set_realm_collision]), so the closed gate stops the
## owner's enemies and lets its own through; if the fort is neutral it stops all of them;
## [br]- the child [code]Vista[/code] is the [b]view[/b] body, on structure layer 4
## ([constant PlayerCharacter.STRUCTURE_LAYER]): it stops no one, but the camera and the line of
## sight do not pass through the gate (even if the owner can cross it).
## [br]When broken, both bodies are left with no layers.
## [br][br]
## The server and the client must set the same state on each tick with [method set_state] (owner
## and breakage); health and hits are the fort controller's job.
## [br][br]
## Nodes it expects (created by tools/props/build_vado_gris_props.gd): [code]Hoja1[/code] (north,
## hinge at z = -[constant HALF_WIDTH]) and [code]Hoja2[/code] (south), [code]ColisionCerrada[/code]
## (shape of the movement body) and [code]Vista[/code] with its [code]ColisionVista[/code]. Origin:
## center of the opening at ground level; when closed, it occupies the plane x = 0 and the fort's
## interior is toward +X.

## Half width of the opening (m).
const HALF_WIDTH: float = 2.0
## Height of the leaves (m).
const LEAF_HEIGHT: float = 4.3
## Rotation of the broken leaves (rad, about 95°: somewhat beyond perpendicular).
const OPEN_ANGLE: float = 1.658
## Child with the view body (structure layer).
const VIEW_BODY: NodePath = ^"Vista"
## Child with the closed gate's shape (the box that attacks hit and that occupies the opening).
const CLOSED_SHAPE: NodePath = ^"ColisionCerrada"
## Closed gate box if the scene has no [code]ColisionCerrada[/code]: size and center (in the gate's
## local space).
const DEFAULT_BOX_SIZE: Vector3 = Vector3(0.5, 4.3, 4.0)
const DEFAULT_BOX_CENTER: Vector3 = Vector3(0.0, 2.15, 0.0)
## Codes of the playable realms (those of [RealmCatalog]) that have a movement layer.
const _REALM_CODES: Array[int] = [1, 2, 3]

var _owner_realm: int = 0
var _broken: bool = false


func _ready() -> void:
	_apply()


## Collision layers of the movement body of a gate belonging to [param owner_realm] (0 = neutral
## fort): the realm layers of the other realms. With [param broken] (health 0), 0: it stops no
## one. Static and shared: client and server compute the same.
static func layers_for(owner_realm: int, broken: bool) -> int:
	if broken:
		return 0
	var layers: int = 0
	for code: int in _REALM_CODES:
		if code != owner_realm:
			layers |= PlayerCharacter.realm_layer(code)
	return layers


## Layer of the view body: the structure one while the gate is intact, 0 when broken.
static func view_layer_for(broken: bool) -> int:
	return 0 if broken else PlayerCharacter.STRUCTURE_LAYER


## Sets the gate's state: fort owner ([param owner_realm], 0 if neutral) and whether it is broken.
## It changes the layers of both bodies and the pose of the leaves.
func set_state(owner_realm: int, broken: bool) -> void:
	_owner_realm = owner_realm
	_broken = broken
	_apply()


## Owner realm of the gate (0 = neutral).
func get_owner_realm() -> int:
	return _owner_realm


## true if the gate is broken (health 0): no collision of any kind and with the leaves hanging.
func is_broken() -> bool:
	return _broken


## Rotation (rad) of leaf [param index] (0 = north, 1 = south) in the current state.
func get_leaf_angle(index: int) -> float:
	if not _broken:
		return 0.0
	return -OPEN_ANGLE if index == 0 else OPEN_ANGLE


## View body (structure layer), or null if the scene does not have it.
func get_view_body() -> StaticBody3D:
	return get_node_or_null(VIEW_BODY) as StaticBody3D


## Transform (in the world) of the [b]center[/b] of the closed gate's box: it is what attacks hit
## ([method HitShapes.sector_hits_box]) and what occupies the opening
## ([method HitShapes.capsule_overlaps_box]). It comes from the scene's [code]ColisionCerrada[/code]
## shape or, if it lacks one, from [constant DEFAULT_BOX_CENTER]. Only valid with the gate in the
## tree.
func get_hit_box() -> Transform3D:
	var base: Transform3D = global_transform if is_inside_tree() else transform
	var shape_node: CollisionShape3D = get_node_or_null(CLOSED_SHAPE) as CollisionShape3D
	if shape_node != null:
		return base * shape_node.transform
	return base * Transform3D(Basis(), DEFAULT_BOX_CENTER)


## Half extents of the box of [method get_hit_box].
func get_hit_half_extents() -> Vector3:
	var shape_node: CollisionShape3D = get_node_or_null(CLOSED_SHAPE) as CollisionShape3D
	if shape_node != null:
		var box: BoxShape3D = shape_node.shape as BoxShape3D
		if box != null:
			return box.size * 0.5
	return DEFAULT_BOX_SIZE * 0.5


## The gate's physics bodies (movement and view): the line of sight of hits on the gate itself
## excludes them.
func get_body_rids() -> Array[RID]:
	var rids: Array[RID] = [get_rid()]
	var view: StaticBody3D = get_view_body()
	if view != null:
		rids.append(view.get_rid())
	return rids


func _apply() -> void:
	collision_layer = layers_for(_owner_realm, _broken)
	var view: StaticBody3D = get_view_body()
	if view != null:
		view.collision_layer = view_layer_for(_broken)
	for i: int in 2:
		var hinge: Vector3 = Vector3(0.0, 0.0, -HALF_WIDTH if i == 0 else HALF_WIDTH)
		var leaf_basis: Basis = Basis(Vector3.UP, get_leaf_angle(i))
		var leaf: Node3D = get_node_or_null(NodePath("Hoja%d" % (i + 1))) as Node3D
		if leaf != null:
			# The leaf mesh runs from the hinge toward +Z: the south one is the same rotated 180°.
			var mesh_basis: Basis = Basis() if i == 0 else Basis(Vector3.UP, PI)
			leaf.transform = Transform3D(leaf_basis * mesh_basis, hinge)
