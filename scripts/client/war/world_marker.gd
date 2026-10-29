class_name WorldMarker
extends RefCounted
## Un lugar que la interfaz marca en el mundo (UI-19): el fuerte, su puerta, su círculo de captura, un
## campamento o un paso. Es solo datos (qué, dónde, cómo se llama y de qué color); lo dibujan
## [WorldMarkers] (icono proyectado en la pantalla) y [Compass] (en la brújula), y lo reutilizan el
## minimapa y el mapa. Los crea [MarkerSource].

## Tipos de marcador.
enum Kind { FORT, GATE, CIRCLE, CAMP, PASS }

## Identificador estable (para recordar un marcador entre fotogramas).
var id: StringName = &""
var kind: int = Kind.FORT
## Nombre en español.
var label: String = ""
## Posición en el mundo.
var position: Vector3 = Vector3.ZERO
var color: Color = Color.WHITE
## Reino al que pertenece (código de red), o 0.
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


## Distancia horizontal (m) desde [param origin] al marcador.
func distance_from(origin: Vector3) -> float:
	return Vector2(position.x - origin.x, position.z - origin.z).length()


## Distancia en 3D (m) desde [param origin].
func distance_3d_from(origin: Vector3) -> float:
	return position.distance_to(origin)
