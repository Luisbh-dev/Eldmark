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


## Grupo de nodos que marca los puntos de aparición de una zona (para avisos y registros).
static func spawn_group() -> StringName:
	return Zones.SPAWN_GROUP


static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges().to_lower()
