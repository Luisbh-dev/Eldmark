class_name RespawnPointList
extends RefCounted
## Lista de puntos de reaparición que ofrece la pantalla de muerte (docs/combate.md, sección 5).
## [br][br]
## El cliente la saca de la zona que tiene cargada, en el orden de la escena, y envía al servidor el
## [b]índice dentro de esta lista[/b] en el RESPAWN_REQUEST. Usa la misma función que el servidor
## ([method NetZones.get_respawn_points]): los nodos del grupo de reaparición del reino o, si la
## zona no tiene ninguno, sus puntos de aparición.

## Grupo de los puntos de reaparición de una zona (opcional: sin él valen los de aparición).
const GROUP: StringName = NetZones.RESPAWN_GROUP
## Metadato con el reino de un punto.
const REALM_META: StringName = &"realm"
## Metadato opcional con el nombre que se enseña en la lista.
const TITLE_META: StringName = &"title"


## Puntos del reino [param realm_code] (un [enum NetProtocol.Realm]) en [param world] (en el árbol).
## Es exactamente la lista del servidor ([method NetZones.get_respawn_points]), para que el índice
## del RESPAWN_REQUEST signifique lo mismo en los dos lados. Si está vacía, el servidor usa su
## punto de aparición del reino, y la pantalla ofrece una sola opción.
static func list(world: Node, realm_code: int) -> Array[Node3D]:
	if world == null or not world.is_inside_tree():
		var empty: Array[Node3D] = []
		return empty
	return NetZones.get_respawn_points(world, realm_code)


## Nombre de [param point] para la lista: su metadato [constant TITLE_META] o, si no tiene, el
## nombre del nodo con los guiones bajos como espacios.
static func label_of(point: Node) -> String:
	var title: String = String(point.get_meta(TITLE_META, ""))
	if not title.is_empty():
		return title
	return String(point.name).replace("_", " ")


## Nombres de los puntos de [param points], en el mismo orden.
static func labels(points: Array[Node3D]) -> PackedStringArray:
	var result := PackedStringArray()
	for point: Node3D in points:
		result.append(label_of(point))
	return result
