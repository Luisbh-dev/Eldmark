class_name ZonePlaces
extends RefCounted
## Place names of each zone for the map window (UI-53): the named places that are not a fort, camp or
## pass (the bridges, the ford, the ruins of Eld, the chapel, the forests, the ranges and the river). They are data, not
## a scene: the player reads them on the map and nothing in the game depends on them. Points carry an icon and areas
## ([member MapLandmark.area]) only the name. Client only.

## Place names of Vado Gris: [code][name, x, z, is_area][/code], with north at -Z.
const VADO_GRIS: Array = [
	["Puente del Norte", 0.0, -62.0, false],
	["Puente del Sur", 0.0, 62.0, false],
	["El Vado", -62.0, 0.0, false],
	["Ruinas de Eld", -105.0, -6.0, false],
	["Capilla en ruinas", 77.0, -5.0, false],
	["Pinar de Escarcha", -112.0, -112.0, true],
	["Arboleda del Alba", -112.0, 112.0, true],
	["Río Eldrun", 100.0, -68.0, true],
	["Sierra del Poniente", -176.0, -30.0, true],
	["Sierra del Levante", 176.0, 40.0, true],
]


## Place names of zone [param zone_id] (empty if it has none).
static func for_zone(zone_id: StringName) -> Array[MapLandmark]:
	var places: Array[MapLandmark] = []
	if zone_id != &"vado_gris":
		return places
	for entry: Array in VADO_GRIS:
		places.append(MapLandmark.make(MapLandmark.KIND_PLACE, String(entry[0]),
				Vector3(float(entry[1]), 0.0, float(entry[2])), 0, &"", bool(entry[3])))
	return places
