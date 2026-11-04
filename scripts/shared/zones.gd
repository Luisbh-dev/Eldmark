class_name Zones
extends RefCounted
## Registry of the world's zones: identifier -> scene, and spawn point selection.
##
## Shared: used by the client (to load the zone chosen with [code]--zone=[/code]) and, in phase 2,
## by each zone's dedicated server. It does not depend on anything in [code]scripts/client/[/code].
## [br][br]
## A zone is a scene whose spawn points are [Node3D] nodes of the [constant SPAWN_GROUP] group. If
## a point carries the [constant REALM_META] metadata ([code]"vardheim"[/code],
## [code]"solmarch"[/code]...), it is only for that realm.

## Zone loaded if no other is given.
const DEFAULT_ZONE: StringName = &"vado_gris"
## Zone identifier -> path of its scene.
const SCENES: Dictionary[StringName, String] = {
	&"vado_gris": "res://scenes/world/zones/vado_gris/vado_gris.tscn",
	&"test_world": "res://scenes/world/test_world.tscn",
}

## PvP mode of a zone (docs/combate.md, section 5): in a [code]SAFE[/code] zone enemy realms do
## not damage each other; in an [code]RVR[/code] (realm versus realm) zone they do.
enum PvpMode { SAFE, RVR }

## PvP mode of each registered zone. A zone not listed here is [code]SAFE[/code].
const PVP_MODES: Dictionary[StringName, int] = {
	&"vado_gris": PvpMode.RVR,
	&"test_world": PvpMode.RVR,
}

## Default capacity of each zone's server (players, fake ones too), if [code]--max-players[/code]
## is not passed: in Vado Gris, the war zone, the per-battle player limit measured with the phase 4
## kit (docs/networking.md, section 14; docs/abilities.md, section 11). A zone not listed here uses the
## [code]ServerConfig[/code] one (64).
const MAX_PLAYERS: Dictionary[StringName, int] = {
	&"vado_gris": 40,
}

## Playable realms (see docs/world.md): those of [RealmCatalog].
const REALMS: Array[StringName] = RealmCatalog.REALM_IDS
## Realm used if no other is given.
const DEFAULT_REALM: StringName = RealmCatalog.VARDHEIM

## Group of a zone's spawn points.
const SPAWN_GROUP: StringName = &"spawn_points"
## Metadata with the realm of a spawn point.
const REALM_META: StringName = &"realm"
## Group of a zone's review cameras (Marker3D with the [code]fov[/code] metadata).
const SCREENSHOT_GROUP: StringName = &"screenshot_points"
## Group of respawn points after dying (docs/combate.md, section 5): markers with the
## [constant REALM_META] metadata, in scene order. The client and the server load the same zone, so
## a point's index is the same on both sides. A zone with none uses its spawn points
## ([constant SPAWN_GROUP]).
const RESPAWN_GROUP: StringName = &"respawn_points"
## Group of safe areas (camps): [Marker3D] with the [constant REALM_META] and
## [constant SAFE_AREA_RADIUS_META] metadata. They only protect the players of their realm.
const SAFE_AREA_GROUP: StringName = &"safe_areas"
## Metadata with the radius (m) of a safe area.
const SAFE_AREA_RADIUS_META: StringName = &"radius"
## Radius (m) of a safe area without the [constant SAFE_AREA_RADIUS_META] metadata.
const SAFE_AREA_DEFAULT_RADIUS: float = 24.0
## Group of lethal volumes: [Area3D] (layer 2 mask) that kill whoever enters.
const LETHAL_GROUP: StringName = &"lethal_volumes"
## Group of points where the server places a training dummy when the zone starts.
const DUMMY_GROUP: StringName = &"dummy_points"
## Group of a zone's forts (docs/fortress.md, section 1.6): each fort's node, with the
## [constant FORTRESS_DEFINITION_META] metadata and its markers as children
## ([code]CaptureCircle[/code], [code]CaptainSpawn[/code], [code]GuardSpawn1[/code]..4,
## [code]FortGate[/code], the banners...).
const FORTRESS_GROUP: StringName = &"fortresses"
## Fort metadata with the path of its [code]FortressDefinition[/code] (.tres).
const FORTRESS_DEFINITION_META: StringName = &"definition"
## Metadata of a respawn point inside a fort with the id of its fort (the [code]id[/code] of its
## definition). Camp points carry [constant REALM_META].
const FORTRESS_META: StringName = &"fortress"
## Group of NPC spawners ([NpcSpawner]).
const NPC_SPAWNER_GROUP: StringName = &"npc_spawners"
## Group of markers for NPC patrol routes: [Marker3D] with the [constant PATROL_ROUTE_META]
## metadata, in scene order within each route.
const PATROL_GROUP: StringName = &"patrol_points"
## Metadata with the route id of a patrol marker.
const PATROL_ROUTE_META: StringName = &"route"


## true if [param zone_id] is a registered zone.
static func has_zone(zone_id: StringName) -> bool:
	return SCENES.has(zone_id)


## Scene path of [param zone_id], or an empty string if the zone does not exist.
static func get_scene_path(zone_id: StringName) -> String:
	return SCENES.get(zone_id, "")


## PvP mode of [param zone_id] (a value of [enum PvpMode]). Vado Gris and the test world are RVR;
## an unknown zone is [code]SAFE[/code], the safe option.
static func get_pvp_mode(zone_id: StringName) -> int:
	return PVP_MODES.get(zone_id, PvpMode.SAFE)


## Default capacity of [param zone_id] ([constant MAX_PLAYERS]), or 0 if it has none of its own.
static func get_max_players(zone_id: StringName) -> int:
	return MAX_PLAYERS.get(zone_id, 0)


## Identifiers of all registered zones, sorted.
static func get_zone_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	ids.assign(SCENES.keys())
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids


## true if [param realm] is one of the realms in [constant REALMS].
static func is_realm(realm: StringName) -> bool:
	return RealmCatalog.is_realm(realm)


## Spawn points of [param zone] (descendants of the [constant SPAWN_GROUP] group) in scene order.
## With a non-empty [param realm], only those of that realm. The zone must be in the tree.
static func get_spawn_points(zone: Node, realm: StringName = &"") -> Array[Node3D]:
	var result: Array[Node3D] = []
	if zone == null or not zone.is_inside_tree():
		return result
	for node: Node in zone.get_tree().get_nodes_in_group(SPAWN_GROUP):
		var spawn: Node3D = node as Node3D
		if spawn == null or not (zone == spawn or zone.is_ancestor_of(spawn)):
			continue
		if realm.is_empty() or get_spawn_realm(spawn) == realm:
			result.append(spawn)
	return result


## Realm of a spawn point (empty if it lacks the [constant REALM_META] metadata).
static func get_spawn_realm(spawn: Node) -> StringName:
	return StringName(spawn.get_meta(REALM_META, &""))


## Spawn point for [param realm] in [param zone]: the first of that realm or, if the zone has none
## of that realm, the first of the zone. Returns null if there is none.
static func find_spawn_point(zone: Node, realm: StringName) -> Node3D:
	var for_realm: Array[Node3D] = get_spawn_points(zone, realm)
	if not for_realm.is_empty():
		return for_realm[0]
	var any: Array[Node3D] = get_spawn_points(zone)
	return any[0] if not any.is_empty() else null


## Nodes of [param zone] (descendants) in group [param group], in scene order. The zone must be in
## the tree; nodes that are not [Node3D] are ignored.
static func get_group_nodes(zone: Node, group: StringName) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if zone == null or not zone.is_inside_tree():
		return result
	for node: Node in zone.get_tree().get_nodes_in_group(group):
		var found: Node3D = node as Node3D
		if found != null and (zone == found or zone.is_ancestor_of(found)):
			result.append(found)
	return result


## Respawn points of [param realm] in [param zone], in scene order: the nodes of the
## [constant RESPAWN_GROUP] group with that realm or, if the zone has no node in that group, its
## spawn points ([method get_spawn_points]) of that realm. The list index is the one that travels
## in RESPAWN_REQUEST and RESPAWN.
static func get_respawn_points(zone: Node, realm: StringName) -> Array[Node3D]:
	var all_points: Array[Node3D] = get_group_nodes(zone, RESPAWN_GROUP)
	if all_points.is_empty():
		return get_spawn_points(zone, realm)
	var result: Array[Node3D] = []
	for point: Node3D in all_points:
		if realm.is_empty() or get_spawn_realm(point) == realm:
			result.append(point)
	return result


## Radius (m) of a safe area: its [constant SAFE_AREA_RADIUS_META] metadata or
## [constant SAFE_AREA_DEFAULT_RADIUS] if missing or not a positive number.
static func get_safe_area_radius(area: Node) -> float:
	var value: Variant = area.get_meta(SAFE_AREA_RADIUS_META, SAFE_AREA_DEFAULT_RADIUS)
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return SAFE_AREA_DEFAULT_RADIUS
	var radius: float = float(value)
	return radius if radius > 0.0 and is_finite(radius) else SAFE_AREA_DEFAULT_RADIUS


## Review cameras of [param zone] (group [constant SCREENSHOT_GROUP]) in scene order.
static func get_screenshot_points(zone: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if zone == null or not zone.is_inside_tree():
		return result
	for node: Node in zone.get_tree().get_nodes_in_group(SCREENSHOT_GROUP):
		var marker: Node3D = node as Node3D
		if marker != null and zone.is_ancestor_of(marker):
			result.append(marker)
	return result
