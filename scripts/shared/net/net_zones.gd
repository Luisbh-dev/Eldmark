class_name NetZones
extends RefCounted
## Único contacto de la red con [Zones] (docs/red.md, sección 1.5): zona por defecto, ruta de la
## escena de cada zona, reinos admitidos y lectura de [code]--zone=[/code] y [code]--realm=[/code].
## [br][br]
## En la red el reino viaja como código de [enum NetProtocol.Realm] y la zona como su id de texto
## (ASCII, 32 bytes como mucho). Esta clase traduce en los dos sentidos entre esos códigos y los
## [StringName] de [Zones]. Si [Zones] cambia, solo hay que tocar este archivo.

const _ZONE_ARG_PREFIX: String = "--zone="
const _REALM_ARG_PREFIX: String = "--realm="


## Id de la zona que sirve o carga un proceso sin [code]--zone[/code].
## Grupo de los puntos de reaparición (el de [Zones]), para quien no puede nombrar [Zones].
const RESPAWN_GROUP: StringName = Zones.RESPAWN_GROUP

static func default_zone_id() -> String:
	return String(Zones.DEFAULT_ZONE)


## Ruta de la escena de [param zone_id], o una cadena vacía si la zona no existe.
static func scene_path(zone_id: String) -> String:
	return Zones.get_scene_path(StringName(zone_id))


## Códigos de [enum NetProtocol.Realm] admitidos en [param zone_id], según [RealmCatalog]. Vacío
## = todos: es lo que devuelve para una zona sin restricción registrada.
static func allowed_realms(zone_id: String) -> PackedInt32Array:
	var codes := PackedInt32Array()
	for id: StringName in RealmCatalog.allowed_realm_ids(StringName(zone_id)):
		codes.append(RealmCatalog.code_of(id))
	return codes


## Valor de [code]--zone=<id>[/code] en [param args] (sin espacios ni comillas y en minúsculas),
## o una cadena vacía si no viene. No comprueba que la zona exista: para eso está
## [method scene_path].
static func parse_zone_arg(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(_ZONE_ARG_PREFIX):
			return _clean_value(arg.trim_prefix(_ZONE_ARG_PREFIX))
	return ""


## Reino de [code]--realm=<reino>[/code] en [param args], o [constant NetProtocol.Realm.NONE] si
## no viene o no es un reino válido.
static func parse_realm_arg(args: PackedStringArray) -> int:
	for arg: String in args:
		if arg.begins_with(_REALM_ARG_PREFIX):
			return realm_from_name(arg.trim_prefix(_REALM_ARG_PREFIX))
	return NetProtocol.Realm.NONE


## Código de reino a partir de su nombre («vardheim», «Solmarch»...; sin distinguir mayúsculas
## ni espacios). [constant NetProtocol.Realm.NONE] si no es un reino.
static func realm_from_name(text: String) -> int:
	var id: StringName = StringName(_clean_value(text))
	if not RealmCatalog.is_realm(id):
		return NetProtocol.Realm.NONE
	return RealmCatalog.code_of(id)


## Id en [RealmCatalog] (y en [Zones]) del reino con código [param realm]; vacío si no es un
## reino jugable (el neutral de los Huecos tampoco lo es).
static func realm_name(realm: int) -> StringName:
	var id: StringName = RealmCatalog.id_of_code(realm)
	return id if RealmCatalog.is_realm(id) else &""


## Punto de aparición del reino [param realm] en la zona [param zone] (que debe estar en el
## árbol): el primero de ese reino o, si no hay ninguno, el primero de la zona. null si la zona
## no tiene puntos de aparición.
static func find_spawn_point(zone: Node, realm: int) -> Node3D:
	return Zones.find_spawn_point(zone, realm_name(realm))


## Puntos de aparición de la zona [param zone] (que debe estar en el árbol), en el orden de la
## escena: los del reino [param realm] o, con [constant NetProtocol.Realm.NONE] (o un código que no
## es un reino jugable), los de toda la zona.
static func get_spawn_points(zone: Node, realm: int = NetProtocol.Realm.NONE) -> Array[Node3D]:
	var realm_id: StringName = realm_name(realm)
	if realm_id.is_empty():
		return Zones.get_spawn_points(zone)
	return Zones.get_spawn_points(zone, realm_id)


## Puntos de reaparición del reino [param realm] en la zona [param zone] (que debe estar en el
## árbol), en el orden de la escena ([method Zones.get_respawn_points]). Si el reino no tiene puntos
## propios (o el código no es un reino jugable), todos los de la zona. Es la lista común del servidor
## y del cliente: el índice del RESPAWN_REQUEST va sobre ella.
static func get_respawn_points(zone: Node, realm: int) -> Array[Node3D]:
	var realm_id: StringName = realm_name(realm)
	if not realm_id.is_empty():
		var own: Array[Node3D] = Zones.get_respawn_points(zone, realm_id)
		if not own.is_empty():
			return own
	# Sin puntos del reino (o sin reino): todos los de la zona, como hace SpawnPicker al aparecer.
	return Zones.get_respawn_points(zone, &"")


## Todos los puntos de reaparición de la zona [param zone] (que debe estar en el árbol), de todos los
## reinos y de las fortalezas, en el orden de la escena: la lista [b]estática[/b] sobre la que va el
## índice de RESPAWN_REQUEST y RESPAWN (docs/fuerte.md, sección 5). Qué puntos valen para un jugador lo
## decide [method RespawnRules.points_for]. Una zona sin ningún nodo del grupo
## [constant RESPAWN_GROUP] usa sus puntos de aparición.
static func get_all_respawn_points(zone: Node) -> Array[Node3D]:
	var all_points: Array[Node3D] = Zones.get_group_nodes(zone, Zones.RESPAWN_GROUP)
	if all_points.is_empty():
		return Zones.get_spawn_points(zone)
	return all_points


## Nodos de las fortalezas de la zona [param zone] (grupo [constant Zones.FORTRESS_GROUP]) que
## tienen el metadato [constant Zones.FORTRESS_DEFINITION_META], en el orden de la escena.
static func get_fortress_nodes(zone: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node: Node3D in Zones.get_group_nodes(zone, Zones.FORTRESS_GROUP):
		if node.has_meta(Zones.FORTRESS_DEFINITION_META):
			result.append(node)
	return result


## Metadato con el reino de un punto de aparición o de reaparición (el de un campamento).
static func realm_meta() -> StringName:
	return Zones.REALM_META


## Metadato de la fortaleza con su definición: la ruta del [code].tres[/code] (o la propia
## [FortressDefinition], que usan las pruebas).
static func fortress_definition_meta() -> StringName:
	return Zones.FORTRESS_DEFINITION_META


## Zonas seguras de la zona [param zone] (grupo [constant Zones.SAFE_AREA_GROUP]).
static func get_safe_areas(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.SAFE_AREA_GROUP)


## Volúmenes letales de la zona [param zone] (grupo [constant Zones.LETHAL_GROUP]).
static func get_lethal_volumes(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.LETHAL_GROUP)


## Puntos de los maniquíes de entrenamiento de la zona [param zone] (grupo
## [constant Zones.DUMMY_GROUP]).
static func get_dummy_points(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.DUMMY_GROUP)


## Código de red del reino del metadato [code]realm[/code] de [param node] (un punto de aparición o
## una zona segura), o -1 si no tiene el metadato o no es un reino jugable.
static func node_realm_code(node: Node) -> int:
	var id: StringName = Zones.get_spawn_realm(node)
	if not RealmCatalog.is_realm(id):
		return -1
	return RealmCatalog.code_of(id)


## Radio (m) de una zona segura ([method Zones.get_safe_area_radius]).
static func safe_area_radius(area: Node) -> float:
	return Zones.get_safe_area_radius(area)


## Grupo de nodos que marca los puntos de aparición de una zona (para avisos y registros).
static func spawn_group() -> StringName:
	return Zones.SPAWN_GROUP


static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges().to_lower()
