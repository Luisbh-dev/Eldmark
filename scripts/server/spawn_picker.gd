class_name SpawnPicker
extends RefCounted
## Chooses where each player entering the zone appears (docs/red.md, section 1.5).
## [br][br]
## The points are the nodes of the [method NetZones.spawn_group] group in the zone scene; those with the realm metadata
## belong to that realm ([method NetZones.get_spawn_points]: [NetZones] is the network's only contact with [Zones]).
## [method pick] distributes each realm's points round-robin, so that players who arrive together do not appear stacked.
## If the realm has no points, any of the zone's is used and, if the zone has none, the origin; in both cases with a
## warning (once per realm).

var _world: Node
# Next index of each realm's rotation (realm code -> index). A realm without points of its own rotates through all of
# the zone's with its own index.
var _cursors: Dictionary[int, int] = {}
# Warnings already emitted, so as not to fill the log with every player that enters.
var _warned: Dictionary[String, bool] = {}


## [param world] is the root of the zone scene, which must be in the tree when [method pick] is called.
func _init(world: Node) -> void:
	_world = world


## Spawn point for a player of [param realm] (a code of [enum NetProtocol.Realm]): the next one in that realm's
## rotation. The position is the point's and the basis only has its yaw (where the point faces).
func pick(realm: int) -> Transform3D:
	var points: Array[Node3D] = []
	if not NetZones.realm_name(realm).is_empty():
		points = NetZones.get_spawn_points(_world, realm)
	if points.is_empty():
		points = NetZones.get_spawn_points(_world)
		if not points.is_empty():
			_warn_once("realm_%d" % realm,
					"La zona no tiene puntos de aparición de %s; se usa cualquiera"
					% NetProtocol.realm_display_name(realm))
	if points.is_empty():
		_warn_once("origin", "La zona no tiene nodos en el grupo '%s'; se aparece en el origen"
				% NetZones.spawn_group())
		return Transform3D.IDENTITY
	var cursor: int = _cursors.get(realm, 0)
	var index: int = cursor % points.size()
	_cursors[realm] = index + 1
	return _transform_of(points[index])


# Position of the point and basis with its yaw (the same formula as ClientMain._yaw_from_basis).
static func _transform_of(point: Node3D) -> Transform3D:
	var forward: Vector3 = -point.global_transform.basis.z
	var yaw: float = atan2(-forward.x, -forward.z)
	return Transform3D(Basis(Vector3.UP, yaw), point.global_position)


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("[Eldmark] %s" % message)
