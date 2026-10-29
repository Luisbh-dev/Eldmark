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
