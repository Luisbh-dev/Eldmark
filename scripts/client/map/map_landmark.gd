class_name MapLandmark
extends Resource
## A fixed place in the zone that the map and the markers know how to draw: the fort, a camp or a
## pass (the gate of a wall). It is written by [code]tools/bake_zone_map.gd[/code] into the zone's
## [ZoneMapDefinition] from the scene; the elements that change in game (the owner's
## color, the capture state) are put on top by the interface with what the server says.

## Place types.
const KIND_FORT: StringName = &"fort"
const KIND_CAMP: StringName = &"camp"
const KIND_PASS: StringName = &"pass"
## Place name (UI-53): a named place that is only labeled in the map window (a bridge, the ford, some
## ruins, a forest or a mountain range). It is not a world marker and does not appear on the compass.
const KIND_PLACE: StringName = &"place"

## Type ([constant KIND_FORT], [constant KIND_CAMP] or [constant KIND_PASS]).
@export var kind: StringName = &""
## Name in Spanish.
@export var label: String = ""
## Position in the world (the ground; the height is that of the scene's marker).
@export var position: Vector3 = Vector3.ZERO
## Realm it belongs to (network code: 1 to 3), or 0 if it belongs to none.
@export var realm: int = 0
## Id of the fortress (that of its definition) if it is a fort; empty otherwise.
@export var fortress_id: StringName = &""
## Only on place names: it is an area (a forest, a mountain range, a river) and not a point; it is labeled centered and without an icon.
@export var area: bool = false


static func make(p_kind: StringName, p_label: String, p_position: Vector3, p_realm: int = 0,
		p_fortress_id: StringName = &"", p_area: bool = false) -> MapLandmark:
	var landmark := MapLandmark.new()
	landmark.kind = p_kind
	landmark.label = p_label
	landmark.position = p_position
	landmark.realm = p_realm
	landmark.fortress_id = p_fortress_id
	landmark.area = p_area
	return landmark
