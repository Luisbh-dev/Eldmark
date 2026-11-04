class_name NetZones
extends RefCounted
## The network's only contact with [Zones] (docs/red.md, section 1.5): default zone, scene path of
## each zone, admitted realms, and reading of [code]--zone=[/code] and [code]--realm=[/code].
## [br][br]
## On the network the realm travels as an [enum NetProtocol.Realm] code and the zone as its text id
## (ASCII, 32 bytes at most). This class translates in both directions between those codes and the
## [StringName]s of [Zones]. If [Zones] changes, only this file needs touching.

const _ZONE_ARG_PREFIX: String = "--zone="
const _REALM_ARG_PREFIX: String = "--realm="


## Id of the zone that a process without [code]--zone[/code] serves or loads.
## Group of respawn points (the one from [Zones]), for code that cannot name [Zones].
const RESPAWN_GROUP: StringName = Zones.RESPAWN_GROUP

static func default_zone_id() -> String:
	return String(Zones.DEFAULT_ZONE)


## Scene path of [param zone_id], or an empty string if the zone does not exist.
static func scene_path(zone_id: String) -> String:
	return Zones.get_scene_path(StringName(zone_id))


## true if [param zone_id] is an RvR zone (realm versus realm, [method Zones.get_pvp_mode]): where
## enemy realms damage each other and a player knocked down by another stays knocked down
## (docs/habilidades.md, section 4.5).
static func is_rvr(zone_id: String) -> bool:
	return Zones.get_pvp_mode(StringName(zone_id)) == Zones.PvpMode.RVR


## Default capacity of the [param zone_id] server when [code]--max-players[/code] is not passed
## ([method Zones.get_max_players]); 0 if the zone has none of its own.
static func max_players(zone_id: String) -> int:
	return Zones.get_max_players(StringName(zone_id))


## [enum NetProtocol.Realm] codes admitted in [param zone_id], according to [RealmCatalog]. Empty
## = all: this is what it returns for a zone with no registered restriction.
static func allowed_realms(zone_id: String) -> PackedInt32Array:
	var codes := PackedInt32Array()
	for id: StringName in RealmCatalog.allowed_realm_ids(StringName(zone_id)):
		codes.append(RealmCatalog.code_of(id))
	return codes


## Value of [code]--zone=<id>[/code] in [param args] (without spaces or quotes and in lowercase),
## or an empty string if absent. It does not check that the zone exists: that is what
## [method scene_path] is for.
static func parse_zone_arg(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(_ZONE_ARG_PREFIX):
			return _clean_value(arg.trim_prefix(_ZONE_ARG_PREFIX))
	return ""


## Realm from [code]--realm=<realm>[/code] in [param args], or [constant NetProtocol.Realm.NONE]
## if absent or not a valid realm.
static func parse_realm_arg(args: PackedStringArray) -> int:
	for arg: String in args:
		if arg.begins_with(_REALM_ARG_PREFIX):
			return realm_from_name(arg.trim_prefix(_REALM_ARG_PREFIX))
	return NetProtocol.Realm.NONE


## Path of the baked navigation mesh of zone [param zone_id] (docs/fuerte.md, section 4.1): the
## [code]<scene>_navmesh.tres[/code] file next to the zone scene, or an empty string if the zone
## does not exist or has no mesh (in which case NPCs do not use navigation).
static func navmesh_path(zone_id: String) -> String:
	var scene: String = scene_path(zone_id)
	if scene.is_empty():
		return ""
	var path: String = scene.get_basename() + "_navmesh.tres"
	return path if ResourceLoader.exists(path) else ""


## NPC spawners of zone [param zone] (group [constant Zones.NPC_SPAWNER_GROUP], which must be in
## the tree), in scene order.
static func get_npc_spawners(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.NPC_SPAWNER_GROUP)


## Positions, in scene order, of the markers of patrol route [param route] of zone [param zone]
## (group [constant Zones.PATROL_GROUP] with the metadata [constant Zones.PATROL_ROUTE_META]).
static func get_patrol_route(zone: Node, route: StringName) -> PackedVector3Array:
	var points := PackedVector3Array()
	if route.is_empty():
		return points
	for marker: Node3D in Zones.get_group_nodes(zone, Zones.PATROL_GROUP):
		if StringName(str(marker.get_meta(Zones.PATROL_ROUTE_META, &""))) == route:
			points.append(marker.global_position)
	return points


## Realm code from its name ("vardheim", "Solmarch"...; case- and space-insensitive).
## [constant NetProtocol.Realm.NONE] if it is not a realm.
static func realm_from_name(text: String) -> int:
	var id: StringName = StringName(_clean_value(text))
	if not RealmCatalog.is_realm(id):
		return NetProtocol.Realm.NONE
	return RealmCatalog.code_of(id)


## Id in [RealmCatalog] (and in [Zones]) of the realm with code [param realm]; empty if it is not a
## playable realm (the neutral one of the Hollow is not either).
static func realm_name(realm: int) -> StringName:
	var id: StringName = RealmCatalog.id_of_code(realm)
	return id if RealmCatalog.is_realm(id) else &""


## Spawn point of realm [param realm] in zone [param zone] (which must be in the tree): the first
## one for that realm or, if there is none, the first of the zone. null if the zone has no spawn
## points.
static func find_spawn_point(zone: Node, realm: int) -> Node3D:
	return Zones.find_spawn_point(zone, realm_name(realm))


## Spawn points of zone [param zone] (which must be in the tree), in scene order: those of realm
## [param realm] or, with [constant NetProtocol.Realm.NONE] (or a code that is not a playable
## realm), those of the whole zone.
static func get_spawn_points(zone: Node, realm: int = NetProtocol.Realm.NONE) -> Array[Node3D]:
	var realm_id: StringName = realm_name(realm)
	if realm_id.is_empty():
		return Zones.get_spawn_points(zone)
	return Zones.get_spawn_points(zone, realm_id)


## Respawn points of realm [param realm] in zone [param zone] (which must be in the tree), in
## scene order ([method Zones.get_respawn_points]). If the realm has no points of its own (or the
## code is not a playable realm), all those of the zone. It is the list shared by server and
## client: the RESPAWN_REQUEST index refers to it.
static func get_respawn_points(zone: Node, realm: int) -> Array[Node3D]:
	var realm_id: StringName = realm_name(realm)
	if not realm_id.is_empty():
		var own: Array[Node3D] = Zones.get_respawn_points(zone, realm_id)
		if not own.is_empty():
			return own
	# No points for the realm (or no realm): all those of the zone, as SpawnPicker does when spawning.
	return Zones.get_respawn_points(zone, &"")


## All respawn points of zone [param zone] (which must be in the tree), of all realms and of the
## forts, in scene order: the [b]static[/b] list that the RESPAWN_REQUEST and RESPAWN index
## refers to (docs/fuerte.md, section 5). Which points are valid for a player is decided by
## [method RespawnRules.points_for]. A zone with no node in the group
## [constant RESPAWN_GROUP] uses its spawn points.
static func get_all_respawn_points(zone: Node) -> Array[Node3D]:
	var all_points: Array[Node3D] = Zones.get_group_nodes(zone, Zones.RESPAWN_GROUP)
	if all_points.is_empty():
		return Zones.get_spawn_points(zone)
	return all_points


## Fort nodes of zone [param zone] (group [constant Zones.FORTRESS_GROUP]) that have the
## metadata [constant Zones.FORTRESS_DEFINITION_META], in scene order.
static func get_fortress_nodes(zone: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node: Node3D in Zones.get_group_nodes(zone, Zones.FORTRESS_GROUP):
		if node.has_meta(Zones.FORTRESS_DEFINITION_META):
			result.append(node)
	return result


## Metadata with the realm of a spawn or respawn point (that of a camp).
static func realm_meta() -> StringName:
	return Zones.REALM_META


## Fort metadata with its definition: the path of the [code].tres[/code] (or the
## [FortressDefinition] itself, which tests use).
static func fortress_definition_meta() -> StringName:
	return Zones.FORTRESS_DEFINITION_META


## Safe areas of zone [param zone] (group [constant Zones.SAFE_AREA_GROUP]).
static func get_safe_areas(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.SAFE_AREA_GROUP)


## Lethal volumes of zone [param zone] (group [constant Zones.LETHAL_GROUP]).
static func get_lethal_volumes(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.LETHAL_GROUP)


## Training dummy points of zone [param zone] (group
## [constant Zones.DUMMY_GROUP]).
static func get_dummy_points(zone: Node) -> Array[Node3D]:
	return Zones.get_group_nodes(zone, Zones.DUMMY_GROUP)


## Network code of the realm in the [code]realm[/code] metadata of [param node] (a spawn point or
## a safe area), or -1 if it has no metadata or it is not a playable realm.
static func node_realm_code(node: Node) -> int:
	var id: StringName = Zones.get_spawn_realm(node)
	if not RealmCatalog.is_realm(id):
		return -1
	return RealmCatalog.code_of(id)


## Radius (m) of a safe area ([method Zones.get_safe_area_radius]).
static func safe_area_radius(area: Node) -> float:
	return Zones.get_safe_area_radius(area)


## Node group that marks the spawn points of a zone (for warnings and logs).
static func spawn_group() -> StringName:
	return Zones.SPAWN_GROUP


static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges().to_lower()
