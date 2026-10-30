class_name Zones
extends RefCounted
## Registro de zonas del mundo: identificador -> escena, y elección del punto de aparición.
##
## Compartido: lo usan el cliente (para cargar la zona elegida con [code]--zone=[/code]) y, en
## la fase 2, el servidor dedicado de cada zona. No depende de nada de [code]scripts/client/[/code].
## [br][br]
## Una zona es una escena cuyos puntos de aparición son nodos [Node3D] del grupo
## [constant SPAWN_GROUP]. Si un punto lleva el metadato [constant REALM_META]
## ([code]"vardheim"[/code], [code]"solmarch"[/code]...), solo es para ese reino.

## Zona que se carga si no se indica otra.
const DEFAULT_ZONE: StringName = &"vado_gris"
## Identificador de zona -> ruta de su escena.
const SCENES: Dictionary[StringName, String] = {
	&"vado_gris": "res://scenes/world/zones/vado_gris/vado_gris.tscn",
	&"test_world": "res://scenes/world/test_world.tscn",
}

## Modo PvP de una zona (docs/combate.md, sección 5): en una zona [code]SAFE[/code] los reinos
## enemigos no se dañan entre sí; en una [code]RVR[/code] (reino contra reino) sí.
enum PvpMode { SAFE, RVR }

## Modo PvP de cada zona registrada. Una zona que no figura aquí es [code]SAFE[/code].
const PVP_MODES: Dictionary[StringName, int] = {
	&"vado_gris": PvpMode.RVR,
	&"test_world": PvpMode.RVR,
}

## Aforo por defecto del servidor de cada zona (jugadores, también los falsos), si no se pasa
## [code]--max-players[/code]: en el Vado Gris, la zona de guerra, el límite de jugadores por batalla medido con
## el kit de la fase 4 (docs/red.md, sección 14; docs/habilidades.md, sección 11). Una zona que no figura aquí
## usa el de [code]ServerConfig[/code] (64).
const MAX_PLAYERS: Dictionary[StringName, int] = {
	&"vado_gris": 40,
}

## Reinos jugables (ver docs/mundo.md): los de [RealmCatalog].
const REALMS: Array[StringName] = RealmCatalog.REALM_IDS
## Reino que se usa si no se indica otro.
const DEFAULT_REALM: StringName = RealmCatalog.VARDHEIM

## Grupo de los puntos de aparición de una zona.
const SPAWN_GROUP: StringName = &"spawn_points"
## Metadato con el reino de un punto de aparición.
const REALM_META: StringName = &"realm"
## Grupo de las cámaras de revisión de una zona (Marker3D con el metadato [code]fov[/code]).
const SCREENSHOT_GROUP: StringName = &"screenshot_points"
## Grupo de los puntos de reaparición tras morir (docs/combate.md, sección 5): marcadores con el
## metadato [constant REALM_META], en el orden de la escena. El cliente y el servidor cargan la misma
## zona, así que el índice de un punto es el mismo en los dos lados. Una zona sin ninguno usa sus
## puntos de aparición ([constant SPAWN_GROUP]).
const RESPAWN_GROUP: StringName = &"respawn_points"
## Grupo de las zonas seguras (campamentos): [Marker3D] con los metadatos [constant REALM_META] y
## [constant SAFE_AREA_RADIUS_META]. Solo protegen a los jugadores de su reino.
const SAFE_AREA_GROUP: StringName = &"safe_areas"
## Metadato con el radio (m) de una zona segura.
const SAFE_AREA_RADIUS_META: StringName = &"radius"
## Radio (m) de una zona segura sin el metadato [constant SAFE_AREA_RADIUS_META].
const SAFE_AREA_DEFAULT_RADIUS: float = 24.0
## Grupo de los volúmenes letales: [Area3D] (máscara de la capa 2) que matan a quien entra.
const LETHAL_GROUP: StringName = &"lethal_volumes"
## Grupo de los puntos donde el servidor coloca un maniquí de entrenamiento al arrancar la zona.
const DUMMY_GROUP: StringName = &"dummy_points"
## Grupo de las fortalezas de una zona (docs/fuerte.md, sección 1.6): el nodo de cada fuerte, con el
## metadato [constant FORTRESS_DEFINITION_META] y como hijos sus marcadores ([code]CaptureCircle[/code],
## [code]CaptainSpawn[/code], [code]GuardSpawn1[/code]..4, [code]FortGate[/code], los estandartes...).
const FORTRESS_GROUP: StringName = &"fortresses"
## Metadato de una fortaleza con la ruta de su [code]FortressDefinition[/code] (.tres).
const FORTRESS_DEFINITION_META: StringName = &"definition"
## Metadato de un punto de reaparición del interior de un fuerte con el id de su fortaleza (el
## [code]id[/code] de su definición). Los puntos de los campamentos llevan [constant REALM_META].
const FORTRESS_META: StringName = &"fortress"
## Grupo de los generadores de PNJ ([NpcSpawner]).
const NPC_SPAWNER_GROUP: StringName = &"npc_spawners"
## Grupo de los marcadores de las rutas de patrulla de los PNJ: [Marker3D] con el metadato
## [constant PATROL_ROUTE_META], en el orden de la escena dentro de cada ruta.
const PATROL_GROUP: StringName = &"patrol_points"
## Metadato con el id de la ruta de un marcador de patrulla.
const PATROL_ROUTE_META: StringName = &"route"


## true si [param zone_id] es una zona registrada.
static func has_zone(zone_id: StringName) -> bool:
	return SCENES.has(zone_id)


## Ruta de la escena de [param zone_id], o una cadena vacía si la zona no existe.
static func get_scene_path(zone_id: StringName) -> String:
	return SCENES.get(zone_id, "")


## Modo PvP de [param zone_id] (un valor de [enum PvpMode]). El Vado Gris y el mundo de pruebas
## son RVR; una zona desconocida es [code]SAFE[/code], la opción segura.
static func get_pvp_mode(zone_id: StringName) -> int:
	return PVP_MODES.get(zone_id, PvpMode.SAFE)


## Aforo por defecto de [param zone_id] ([constant MAX_PLAYERS]), o 0 si no tiene uno propio.
static func get_max_players(zone_id: StringName) -> int:
	return MAX_PLAYERS.get(zone_id, 0)


## Identificadores de todas las zonas registradas, ordenados.
static func get_zone_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	ids.assign(SCENES.keys())
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids


## true si [param realm] es uno de los reinos de [constant REALMS].
static func is_realm(realm: StringName) -> bool:
	return RealmCatalog.is_realm(realm)


## Puntos de aparición de [param zone] (descendientes del grupo [constant SPAWN_GROUP]) en el
## orden de la escena. Con [param realm] no vacío, solo los de ese reino. La zona debe estar
## en el árbol.
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


## Reino de un punto de aparición (vacío si no tiene el metadato [constant REALM_META]).
static func get_spawn_realm(spawn: Node) -> StringName:
	return StringName(spawn.get_meta(REALM_META, &""))


## Punto de aparición para [param realm] en [param zone]: el primero de ese reino o, si la zona
## no tiene ninguno de ese reino, el primero de la zona. Devuelve null si no hay ninguno.
static func find_spawn_point(zone: Node, realm: StringName) -> Node3D:
	var for_realm: Array[Node3D] = get_spawn_points(zone, realm)
	if not for_realm.is_empty():
		return for_realm[0]
	var any: Array[Node3D] = get_spawn_points(zone)
	return any[0] if not any.is_empty() else null


## Nodos de [param zone] (descendientes) del grupo [param group], en el orden de la escena. La zona
## debe estar en el árbol; los nodos que no son [Node3D] se ignoran.
static func get_group_nodes(zone: Node, group: StringName) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if zone == null or not zone.is_inside_tree():
		return result
	for node: Node in zone.get_tree().get_nodes_in_group(group):
		var found: Node3D = node as Node3D
		if found != null and (zone == found or zone.is_ancestor_of(found)):
			result.append(found)
	return result


## Puntos de reaparición de [param realm] en [param zone], en el orden de la escena: los nodos del
## grupo [constant RESPAWN_GROUP] con ese reino o, si la zona no tiene ningún nodo en ese grupo, sus
## puntos de aparición ([method get_spawn_points]) de ese reino. El índice de la lista es el que viaja
## en RESPAWN_REQUEST y RESPAWN.
static func get_respawn_points(zone: Node, realm: StringName) -> Array[Node3D]:
	var all_points: Array[Node3D] = get_group_nodes(zone, RESPAWN_GROUP)
	if all_points.is_empty():
		return get_spawn_points(zone, realm)
	var result: Array[Node3D] = []
	for point: Node3D in all_points:
		if realm.is_empty() or get_spawn_realm(point) == realm:
			result.append(point)
	return result


## Radio (m) de una zona segura: su metadato [constant SAFE_AREA_RADIUS_META] o
## [constant SAFE_AREA_DEFAULT_RADIUS] si falta o no es un número positivo.
static func get_safe_area_radius(area: Node) -> float:
	var value: Variant = area.get_meta(SAFE_AREA_RADIUS_META, SAFE_AREA_DEFAULT_RADIUS)
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return SAFE_AREA_DEFAULT_RADIUS
	var radius: float = float(value)
	return radius if radius > 0.0 and is_finite(radius) else SAFE_AREA_DEFAULT_RADIUS


## Cámaras de revisión de [param zone] (grupo [constant SCREENSHOT_GROUP]) en el orden de la
## escena.
static func get_screenshot_points(zone: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if zone == null or not zone.is_inside_tree():
		return result
	for node: Node in zone.get_tree().get_nodes_in_group(SCREENSHOT_GROUP):
		var marker: Node3D = node as Node3D
		if marker != null and zone.is_ancestor_of(marker):
			result.append(marker)
	return result
