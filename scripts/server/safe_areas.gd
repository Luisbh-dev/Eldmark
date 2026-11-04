class_name SafeAreas
extends RefCounted
## Safe zones of a zone (docs/combate.md, section 5; GUE-03): the camps of Vado Gris.
## [br][br]
## Each is a [Marker3D] in the [constant Zones.SAFE_AREA_GROUP] group with the [code]realm[/code] metadata (whom it
## protects) and [code]radius[/code] (24 m by default). It only protects its realm: a player of that realm inside it
## neither receives nor deals damage (one cannot attack safely from inside), and an enemy intruder inside can be
## damaged.
## [br][br]
## Distance is measured on the horizontal plane from the marker. Marker positions do not change, so they are read once
## at construction ([method from_world]).

## A safe zone.
class Area:
	var center: Vector3 = Vector3.ZERO
	var radius: float = 24.0
	## Network code of the realm it protects.
	var realm: int = -1


var _areas: Array[Area] = []


## Reads the safe zones of the zone [param world] (which must be in the tree). A marker without a valid realm in its
## metadata is ignored.
static func from_world(world: Node) -> SafeAreas:
	var result := SafeAreas.new()
	for marker: Node3D in NetZones.get_safe_areas(world):
		var realm: int = NetZones.node_realm_code(marker)
		if realm < 0:
			continue
		result.add(marker.global_position, NetZones.safe_area_radius(marker), realm)
	return result


## Adds a safe zone of realm [param realm] centered at [param center].
func add(center: Vector3, radius: float, realm: int) -> void:
	var area := Area.new()
	area.center = center
	area.radius = radius
	area.realm = realm
	_areas.append(area)


## Number of safe zones.
func size() -> int:
	return _areas.size()


## true if [param position] is inside a safe zone of realm [param realm] (that of its own realm: those of other realms
## do not protect it).
func contains_own(realm: int, position: Vector3) -> bool:
	for area: Area in _areas:
		if area.realm != realm:
			continue
		var offset := Vector2(position.x - area.center.x, position.z - area.center.z)
		if offset.length_squared() <= area.radius * area.radius:
			return true
	return false
