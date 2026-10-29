class_name SafeAreas
extends RefCounted
## Zonas seguras de una zona (docs/combate.md, sección 5; GUE-03): los campamentos del Vado Gris.
## [br][br]
## Cada una es un [Marker3D] del grupo [constant Zones.SAFE_AREA_GROUP] con el metadato
## [code]realm[/code] (a quién protege) y [code]radius[/code] (24 m por defecto). Solo protege a su
## reino: un jugador de ese reino dentro de ella ni recibe ni hace daño (no se puede atacar a salvo
## desde dentro), y un intruso enemigo dentro sí es dañable.
## [br][br]
## La distancia se mide en el plano horizontal desde el marcador. Las posiciones de los marcadores no
## cambian, así que se leen una vez al construir ([method from_world]).

## Una zona segura.
class Area:
	var center: Vector3 = Vector3.ZERO
	var radius: float = 24.0
	## Código de red del reino al que protege.
	var realm: int = -1


var _areas: Array[Area] = []


## Lee las zonas seguras de la zona [param world] (que debe estar en el árbol). Un marcador sin un
## reino válido en su metadato se ignora.
static func from_world(world: Node) -> SafeAreas:
	var result := SafeAreas.new()
	for marker: Node3D in NetZones.get_safe_areas(world):
		var realm: int = NetZones.node_realm_code(marker)
		if realm < 0:
			continue
		result.add(marker.global_position, NetZones.safe_area_radius(marker), realm)
	return result


## Añade una zona segura del reino [param realm] centrada en [param center].
func add(center: Vector3, radius: float, realm: int) -> void:
	var area := Area.new()
	area.center = center
	area.radius = radius
	area.realm = realm
	_areas.append(area)


## Número de zonas seguras.
func size() -> int:
	return _areas.size()


## true si [param position] está dentro de una zona segura del reino [param realm] (la de su
## propio reino: las de los demás no le protegen).
func contains_own(realm: int, position: Vector3) -> bool:
	for area: Area in _areas:
		if area.realm != realm:
			continue
		var offset := Vector2(position.x - area.center.x, position.z - area.center.z)
		if offset.length_squared() <= area.radius * area.radius:
			return true
	return false
