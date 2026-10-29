class_name MapLandmark
extends Resource
## Un lugar fijo de la zona que el mapa y los marcadores saben dibujar: el fuerte, un campamento o un
## paso (la puerta de una muralla). Lo escribe [code]tools/bake_zone_map.gd[/code] en la
## [ZoneMapDefinition] de la zona a partir de la escena; los elementos que cambian en juego (el color
## del dueño, el estado de la captura) los pone encima la interfaz con lo que dice el servidor.

## Tipos de lugar.
const KIND_FORT: StringName = &"fort"
const KIND_CAMP: StringName = &"camp"
const KIND_PASS: StringName = &"pass"

## Tipo ([constant KIND_FORT], [constant KIND_CAMP] o [constant KIND_PASS]).
@export var kind: StringName = &""
## Nombre en español.
@export var label: String = ""
## Posición en el mundo (el suelo; la altura es la del marcador de la escena).
@export var position: Vector3 = Vector3.ZERO
## Reino al que pertenece (código de red: 1 a 3), o 0 si no es de ninguno.
@export var realm: int = 0
## Id de la fortaleza (el de su definición) si es un fuerte; vacío en lo demás.
@export var fortress_id: StringName = &""


static func make(p_kind: StringName, p_label: String, p_position: Vector3, p_realm: int = 0,
		p_fortress_id: StringName = &"") -> MapLandmark:
	var landmark := MapLandmark.new()
	landmark.kind = p_kind
	landmark.label = p_label
	landmark.position = p_position
	landmark.realm = p_realm
	landmark.fortress_id = p_fortress_id
	return landmark
