class_name RespawnPointList
extends RefCounted
## Lista de puntos de reaparición que ofrece la pantalla de muerte y el mapa (docs/combate.md, sección
## 5; docs/fuerte.md, sección 5; UI-14, UI-21).
## [br][br]
## [b]Opciones válidas (fase 4).[/b] El índice de un punto es su posición en la lista de [i]todos[/i] los
## marcadores del grupo de reaparición de la zona, en el orden de la escena, y es el que viaja en el
## RESPAWN_REQUEST. El cliente calcula qué puntos valen con la misma regla que el servidor
## ([method RespawnRules.points_for]: el campamento del reino, o el interior de un fuerte propio en
## reposo y sin ataques) y [method options] los agrupa para el jugador: los marcadores contiguos del
## mismo sitio (los cuatro puntos de un campamento, los del patio de un fuerte) son [b]una sola
## opción[/b], cuyo índice se reparte entre sus puntos según el jugador ([method Option.index_for]) para
## que no reaparezcan todos encima. Si la zona no tiene marcadores de reaparición se usan los de
## aparición del reino, como el servidor.
## [br][br]
## [b]Lista antigua.[/b] [method list] y [method labels] siguen dando la lista filtrada por reino de la fase
## 3 (la usan el servidor mientras no adopte [RespawnRules] y las zonas sin fortalezas).

## Grupo de los puntos de reaparición de una zona (opcional: sin él valen los de aparición).
const GROUP: StringName = NetZones.RESPAWN_GROUP
## Metadato con el reino de un punto.
const REALM_META: StringName = &"realm"
## Metadato opcional con el nombre que se enseña en la lista.
const TITLE_META: StringName = &"title"
## Metadato con el id de la fortaleza de un punto del interior de un fuerte.
const FORTRESS_META: StringName = &"fortress"
## Metros máximos entre dos puntos para que cuenten como el mismo sitio.
const SAME_PLACE_METERS: float = 20.0
const TEXT_CAMP: String = "Campamento de %s"
const TEXT_FORTRESS: String = "%s"


## Un sitio donde se puede reaparecer: uno o varios marcadores contiguos.
class Option extends RefCounted:
	## Índices (en la lista de todos los marcadores de la zona) de sus marcadores, en orden.
	var members: PackedInt32Array = PackedInt32Array()
	var label: String = ""
	## Centro de sus marcadores.
	var position: Vector3 = Vector3.ZERO
	## true si el jugador puede reaparecer aquí ahora.
	var valid: bool = false
	## Reino del campamento (código de red) o 0; y fortaleza si es el interior de un fuerte.
	var realm: int = 0
	var fortress_id: StringName = &""


	## Índice que se envía al servidor: uno de [member members], repartido según [param seed] (el id de
	## red del jugador) para que quienes reaparecen juntos no se apilen.
	func index_for(spread_seed: int) -> int:
		if members.is_empty():
			return 0
		return members[posmod(spread_seed, members.size())]


	## true si el marcador [param point_index] es uno de los de esta opción.
	func has_member(point_index: int) -> bool:
		return members.has(point_index)


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
## nombre del nodo con los guiones bajos como espacios (y las mayúsculas de «CampamentoVardheim»
## separadas).
static func label_of(point: Node) -> String:
	var title: String = String(point.get_meta(TITLE_META, ""))
	if not title.is_empty():
		return title
	return _label_from_name(String(point.name))


## Nombres de [param points], en el mismo orden.
static func labels(points: Array[Node3D]) -> PackedStringArray:
	var result := PackedStringArray()
	for point: Node3D in points:
		result.append(label_of(point))
	return result


## Todos los marcadores de reaparición de [param world] (en el árbol), en el orden de la escena: el
## índice de cada uno es su índice de reaparición.
static func all_points(world: Node) -> Array[Node3D]:
	var points: Array[Node3D] = []
	if world == null or not world.is_inside_tree():
		return points
	for node: Node in world.get_tree().get_nodes_in_group(GROUP):
		var point: Node3D = node as Node3D
		if point != null and (point == world or world.is_ancestor_of(point)):
			points.append(point)
	return points


## Opciones de reaparición del reino [param realm_code] en el tick [param tick] del servidor, válidas o
## no (el mapa enseña las demás apagadas), en el orden de la escena. [param fortresses] asocia el id de
## cada fortaleza con su [FortressState] ([method FortressView.get_states_by_definition]) y
## [param fortress_names] su nombre para la interfaz (vacío = el del nodo). Sin marcadores de
## reaparición se ofrecen los de aparición del reino, todos válidos.
static func options(world: Node, realm_code: int, fortresses: Dictionary, tick: int,
		fortress_names: Dictionary = {}) -> Array[Option]:
	var result: Array[Option] = []
	var points: Array[Node3D] = all_points(world)
	if points.is_empty():
		# Sin grupo propio: los puntos de aparición del reino, un índice cada uno, todos válidos.
		var fallback: Array[Node3D] = list(world, realm_code)
		for index: int in fallback.size():
			var option := Option.new()
			option.members = PackedInt32Array([index])
			option.label = label_of(fallback[index])
			option.position = _position_of(fallback[index])
			option.valid = true
			option.realm = realm_code
			result.append(option)
		return result
	var valid: PackedInt32Array = RespawnRules.points_for(realm_code, points, fortresses, tick)
	var keys: Array[String] = []
	for index: int in points.size():
		var point: Node3D = points[index]
		var position: Vector3 = _position_of(point)
		var key: String = _group_key(point)
		var found: int = -1
		for i: int in result.size():
			if keys[i] == key and result[i].position.distance_to(position) <= SAME_PLACE_METERS:
				found = i
				break
		if found < 0:
			var option := Option.new()
			option.position = position
			option.label = _option_label(point, fortress_names)
			option.realm = RealmCatalog.code_of(StringName(point.get_meta(REALM_META, &"")))
			option.fortress_id = StringName(point.get_meta(FORTRESS_META, &""))
			result.append(option)
			keys.append(key)
			found = result.size() - 1
		var member_count: int = result[found].members.size()
		result[found].position = (result[found].position * float(member_count) + position) / float(member_count + 1) \
				if member_count > 0 else position
		result[found].members.append(index)
		result[found].valid = result[found].valid or valid.has(index)
	return result


## Solo las opciones válidas de [method options].
static func valid_options(world: Node, realm_code: int, fortresses: Dictionary, tick: int,
		fortress_names: Dictionary = {}) -> Array[Option]:
	var found: Array[Option] = []
	for option: Option in options(world, realm_code, fortresses, tick, fortress_names):
		if option.valid:
			found.append(option)
	return found


## Nombres de [param options_list] para la lista de la pantalla de muerte, en el mismo orden.
static func option_labels(options_list: Array[Option]) -> PackedStringArray:
	var result := PackedStringArray()
	for option: Option in options_list:
		result.append(option.label)
	return result


## Índices que se envían al servidor por cada opción de [param options_list], para el jugador de red
## [param spread_seed].
static func option_indices(options_list: Array[Option], spread_seed: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for option: Option in options_list:
		result.append(option.index_for(spread_seed))
	return result


static func _position_of(point: Node3D) -> Vector3:
	return point.global_position if point.is_inside_tree() else point.position


# Marcadores contiguos del mismo sitio: mismo reino o fortaleza y mismo nombre sin el número final.
static func _group_key(point: Node3D) -> String:
	var stem: String = String(point.name).rstrip("0123456789 _")
	return "%s|%s|%s" % [String(point.get_meta(REALM_META, &"")), String(point.get_meta(FORTRESS_META, &"")), stem]


static func _option_label(point: Node3D, fortress_names: Dictionary) -> String:
	var title: String = String(point.get_meta(TITLE_META, ""))
	if not title.is_empty():
		return title
	var fortress_id: StringName = StringName(point.get_meta(FORTRESS_META, &""))
	if fortress_id != &"" and fortress_names.has(fortress_id):
		return String(fortress_names[fortress_id])
	var realm_id: StringName = StringName(point.get_meta(REALM_META, &""))
	var stem: String = String(point.name).rstrip("0123456789 _")
	if realm_id != &"" and fortress_id == &"" and stem.to_lower().begins_with("campamento") \
			and RealmCatalog.has_faction(realm_id):
		return TEXT_CAMP % RealmCatalog.display_name(realm_id)
	return _label_from_name(stem if not stem.is_empty() else String(point.name))


# «Campamento_Norte» -> «Campamento Norte»; «FuerteVadoGris» -> «Fuerte Vado Gris».
static func _label_from_name(node_name: String) -> String:
	if node_name.contains("_"):
		return node_name.replace("_", " ")
	return node_name.capitalize()
