class_name NpcSpawner
extends Marker3D
## NPC spawner of a zone (docs/fortress.md, section 4.3): a scene marker with the data the server
## needs to place and replenish a type of NPC. Data only: whoever creates and removes the entities
## is the server's spawner system ([code]NpcSpawnerSystem[/code]), which looks for the nodes of the
## [constant GROUP] group. The zone scene (client and server) carries these nodes, but the client
## does nothing with them.
## [br][br]
## The marker's position and orientation are those of the NPC when it spawns. If the condition
## talks about the fort ([constant Condition.FORT_NEUTRAL], [constant Condition.FORT_OWNER]), the
## fort is the ancestor in the [constant Zones.FORTRESS_GROUP] group ([method get_fortress]).
## [br][br]
## It does not depend on anything in [code]scripts/client/[/code] or [code]scripts/server/[/code].

## When the spawner is active.
enum Condition {
	## Always.
	ALWAYS,
	## Only while the fort has no owner (it is held by the Hollow and the Ford Captain).
	FORT_NEUTRAL,
	## Only while the fort has an owner and it is of realm [member realm] (the owner's garrison).
	FORT_OWNER,
}

## Group of all spawners of a zone.
const GROUP: StringName = Zones.NPC_SPAWNER_GROUP

## Id of the NPC definition it spawns: the file name in [code]data/npcs/[/code] without the
## extension (for example [code]hollow[/code], [code]ford_captain[/code],
## [code]gate_guardian[/code]). The [code]NpcDefinition[/code] arrives with the NPC package; until
## then it is just the id.
@export var npc_id: StringName = &""
## How many NPCs from this spawner can be alive at once.
@export_range(1, 16) var max_alive: int = 1
## Seconds until a dead NPC respawns. 0 = no respawn of its own: whoever controls the spawner
## replenishes it (the Hollow and the Captain respawn with the fort, docs/fortress.md 1.5).
@export_range(0.0, 3600.0, 0.5, "suffix:s") var respawn_s: float = 0.0
## Alert group: NPCs with the same group warn each other when entering combat.
@export var alert_group: StringName = &""
## When it is active ([enum Condition]).
@export var condition: Condition = Condition.ALWAYS
## Side of the NPCs it spawns ([RealmCatalog] id); empty = neutral (the Hollow). With the
## [constant Condition.FORT_OWNER] condition the fort's owner decides and this field is not used.
@export var realm: StringName = &""
## Patrol route: route id ([code]route[/code] metadata of the markers in the
## [constant Zones.PATROL_GROUP] group); empty = the NPC stays at its post.
@export var patrol_route: StringName = &""


## Respawn seconds converted to physics ticks (0 = no respawn of its own).
func get_respawn_ticks() -> int:
	return roundi(respawn_s * float(Engine.physics_ticks_per_second))


## Fort (node in the [constant Zones.FORTRESS_GROUP] group) this spawner hangs from, or null if it
## hangs from none.
func get_fortress() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node.is_in_group(Zones.FORTRESS_GROUP):
			return node
		node = node.get_parent()
	return null
