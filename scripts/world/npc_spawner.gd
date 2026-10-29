class_name NpcSpawner
extends Marker3D
## Generador de PNJ de una zona (docs/fuerte.md, sección 4.3): un marcador de la escena con los
## datos que necesita el servidor para colocar y reponer un tipo de PNJ. Solo datos: quien crea
## y retira las entidades es el sistema de generadores del servidor ([code]NpcSpawnerSystem[/code]),
## que busca los nodos del grupo [constant GROUP]. La escena de la zona (cliente y servidor) lleva
## estos nodos, pero el cliente no hace nada con ellos.
## [br][br]
## La posición y la orientación del marcador son las del PNJ al aparecer. Si la condición habla del
## fuerte ([constant Condition.FORT_NEUTRAL], [constant Condition.FORT_OWNER]), el fuerte es el
## ancestro del grupo [constant Zones.FORTRESS_GROUP] ([method get_fortress]).
## [br][br]
## No depende de nada de [code]scripts/client/[/code] ni de [code]scripts/server/[/code].

## Cuándo está activo el generador.
enum Condition {
	## Siempre.
	ALWAYS,
	## Solo mientras el fuerte no tiene dueño (lo guardan los Huecos y el Capitán del Vado).
	FORT_NEUTRAL,
	## Solo mientras el fuerte tiene dueño y es del reino [member realm] (la guarnición del dueño).
	FORT_OWNER,
}

## Grupo de todos los generadores de una zona.
const GROUP: StringName = Zones.NPC_SPAWNER_GROUP

## Id de la definición de PNJ que genera: el nombre del archivo en [code]data/npcs/[/code] sin la
## extensión (por ejemplo [code]hollow[/code], [code]ford_captain[/code], [code]gate_guardian[/code]).
## La [code]NpcDefinition[/code] llega con el paquete de PNJ; hasta entonces es solo el id.
@export var npc_id: StringName = &""
## Cuántos PNJ de este generador puede haber vivos a la vez.
@export_range(1, 16) var max_alive: int = 1
## Segundos hasta que reaparece un PNJ muerto. 0 = sin reaparición propia: lo repone quien manda
## sobre el generador (los Huecos y el Capitán reaparecen con la fortaleza, docs/fuerte.md 1.5).
@export_range(0.0, 3600.0, 0.5, "suffix:s") var respawn_s: float = 0.0
## Grupo de alerta: los PNJ con el mismo grupo se avisan entre sí al entrar en combate.
@export var alert_group: StringName = &""
## Cuándo está activo ([enum Condition]).
@export var condition: Condition = Condition.ALWAYS
## Bando de los PNJ que genera (id de [RealmCatalog]); vacío = neutral (los Huecos). Con la
## condición [constant Condition.FORT_OWNER] manda el dueño del fuerte y este campo no se usa.
@export var realm: StringName = &""
## Ruta de patrulla: id de la ruta (metadato [code]route[/code] de los marcadores del grupo
## [constant Zones.PATROL_GROUP]); vacío = el PNJ se queda en su puesto.
@export var patrol_route: StringName = &""


## Segundos de reaparición convertidos a ticks de física (0 = sin reaparición propia).
func get_respawn_ticks() -> int:
	return roundi(respawn_s * float(Engine.physics_ticks_per_second))


## Fortaleza (nodo del grupo [constant Zones.FORTRESS_GROUP]) de la que cuelga este generador, o
## null si no cuelga de ninguna.
func get_fortress() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node.is_in_group(Zones.FORTRESS_GROUP):
			return node
		node = node.get_parent()
	return null
