class_name WorldMarker
extends RefCounted
## A place the interface marks in the world (UI-19): the fort, its gate, its capture circle, a camp or a
## pass. It is only data (what, where, what it is called and what color); it is drawn by [WorldMarkers]
## (icon projected onto the screen) and [Compass] (on the compass), and reused by the minimap and the map.
## It is created by [MarkerSource].

## Marker kinds.
enum Kind { FORT, GATE, CIRCLE, CAMP, PASS }

## Stable identifier (to remember a marker between frames).
var id: StringName = &""
var kind: int = Kind.FORT
## Name in Spanish.
var label: String = ""
## Position in the world.
var position: Vector3 = Vector3.ZERO
var color: Color = Color.WHITE
## Realm it belongs to (network code), or 0.
var realm: int = 0


static func make(p_id: StringName, p_kind: int, p_label: String, p_position: Vector3, p_color: Color,
		p_realm: int = 0) -> WorldMarker:
	var marker := WorldMarker.new()
	marker.id = p_id
	marker.kind = p_kind
	marker.label = p_label
	marker.position = p_position
	marker.color = p_color
	marker.realm = p_realm
	return marker


## Horizontal distance (m) from [param origin] to the marker.
func distance_from(origin: Vector3) -> float:
	return Vector2(position.x - origin.x, position.z - origin.z).length()


## 3D distance (m) from [param origin].
func distance_3d_from(origin: Vector3) -> float:
	return position.distance_to(origin)
