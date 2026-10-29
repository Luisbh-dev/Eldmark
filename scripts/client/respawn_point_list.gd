class_name RespawnPointList
extends RefCounted
## Lista de puntos de reaparición que ofrece la pantalla de muerte (docs/combate.md, sección 5).
## [br][br]
## El cliente la saca de la zona que tiene cargada, en el orden de la escena, y envía al servidor el
## [b]índice dentro de esta lista[/b] en el RESPAWN_REQUEST. Son los nodos del grupo
## [constant GROUP] con el metadato [code]realm[/code] del reino del jugador; si la zona no tiene
## ninguno de ese grupo, los puntos de aparición ([method NetZones.get_spawn_points]) del reino. Si el
## reino no tiene puntos propios, los de todo el grupo. El servidor aplica la misma regla.

## Grupo de los puntos de reaparición de una zona (opcional: sin él valen los de aparición).
const GROUP: StringName = &"respawn_points"
## Metadato con el reino de un punto.
const REALM_META: StringName = &"realm"
## Metadato opcional con el nombre que se enseña en la lista.
const TITLE_META: StringName = &"title"


## Puntos del reino [param realm_code] (un [enum NetProtocol.Realm]) en [param world] (en el árbol).
static func list(world: Node, realm_code: int) -> Array[Node3D]:
	var points: Array[Node3D] = []
	if world == null or not world.is_inside_tree():
		return points
	var group_points: Array[Node3D] = _group_points(world)
	if not group_points.is_empty():
		var realm_id: StringName = NetZones.realm_name(realm_code)
		for point: Node3D in group_points:
			if not realm_id.is_empty() and StringName(point.get_meta(REALM_META, &"")) == realm_id:
				points.append(point)
		return points if not points.is_empty() else group_points
	points = NetZones.get_spawn_points(world, realm_code)
	if points.is_empty():
		points = NetZones.get_spawn_points(world)
	return points


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


static func _group_points(world: Node) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for node: Node in world.get_tree().get_nodes_in_group(GROUP):
		var point: Node3D = node as Node3D
		if point != null and (world == point or world.is_ancestor_of(point)):
			found.append(point)
	return found
