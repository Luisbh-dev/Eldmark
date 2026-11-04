class_name ZonePlaces
extends RefCounted
## Topónimos de cada zona para la ventana del mapa (UI-53): los lugares con nombre que no son fuerte, campamento ni
## paso (los puentes, el vado, las ruinas de Eld, la capilla, los bosques, las sierras y el río). Son datos, no
## escena: el jugador los lee en el mapa y nada del juego depende de ellos. Los puntos llevan icono y las zonas
## ([member MapLandmark.area]) solo el nombre. Solo cliente.

## Topónimos del Vado Gris: [code][nombre, x, z, es_zona][/code], con el norte en -Z.
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


## Topónimos de la zona [param zone_id] (vacío si no tiene).
static func for_zone(zone_id: StringName) -> Array[MapLandmark]:
	var places: Array[MapLandmark] = []
	if zone_id != &"vado_gris":
		return places
	for entry: Array in VADO_GRIS:
		places.append(MapLandmark.make(MapLandmark.KIND_PLACE, String(entry[0]),
				Vector3(float(entry[1]), 0.0, float(entry[2])), 0, &"", bool(entry[3])))
	return places
