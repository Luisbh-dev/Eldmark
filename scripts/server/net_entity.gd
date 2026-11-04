class_name NetEntity
extends RefCounted
## Entity replicated by the server (docs/networking.md, section 9.1): a player (and, since phase 4,
## NPCs, projectiles and structures).
## [br][br]
## It stores what is needed to replicate it: the network id assigned by [NetEntityRegistry], the
## type, the realm, the spawn tick, the owning peer, the name, the flags, its node and the
## teleport counter. It knows how to write its snapshot record without creating objects
## ([method encode_record]) and its ENTITY_SPAWN message ([method encode_spawn]).
## [br][br]
## It also stores what is seen of its health in snapshots: the record's quantized health
## ([member health_q]) and the own extra block ([member health], [member max_health],
## [member status] and [member respawn_tick]). Whoever carries the health (combat's
## [code]Combatant[/code]) updates them every tick with [method set_health_view]; until someone does, the
## entity is healthy.
## [br][br]
## [member action] is the record's action byte ([method ActionWire.encode]); it is
## updated every tick by the same code that carries the health.

## Seen by all players in the zone, without going through the [InterestPolicy] (fortresses, gates).
const FLAG_ALWAYS_RELEVANT: int = 1 << 0
## Health (and max health) announced while nobody updates it: that of
## [code]CombatRules.health_max[/code].
const DEFAULT_HEALTH: int = 1000

## Network id (1..65535) assigned by [NetEntityRegistry].
var net_id: int
## [enum NetProtocol.EntityKind].
var kind: int
## Code of [enum NetProtocol.Realm].
var realm: int
## Tick at which it was added.
var spawn_tick: int
## Id of the owning peer (0 if no client controls it).
var owner_peer: int = 0
var display_name: String
## Game staff (moderator or higher, the claim's role; docs/platform.md §5.4): its ENTITY_SPAWN
## carries the bit [constant NetMessages.SPAWN_FLAG_STAFF] for the nameplate tag (SOC-14). Always false without the platform.
var is_staff: bool = false
## Marked by a GM command that moves, heals or shows it (docs/progression.md §6.2; set by
## [code]/gm teleport[/code], [code]/gm visible[/code] and DEBUG_COMMANDs 1, 2 and 4, platform.md P7b): while it
## lasts it does not enter the captures list or collect merits or NPCs. Respawning removes it (platform.md P6).
var gm_forced: bool = false
## A GM in invisible mode ([code]/gm invisible[/code], docs/platform.md §9.1, P7b): it does not enter the interest of
## others, deals and takes no damage, does not count in the circle or the scoreboard and collects no rewards. Lasts until
## [code]/gm visible[/code] or until it leaves (not saved); respawning does not remove it.
var gm_invisible: bool = false
## Combination of [constant FLAG_ALWAYS_RELEVANT].
var flags: int = 0
## The entity's node in the server's world: a [PlayerCharacter] if it is a player.
var node: Node3D
## Rises (modulo 4) with each teleport, so the client does not interpolate the jump.
var teleport_counter: int = 0
## Quantized health carried by its snapshot record ([method EntityRecord.quantize_health]).
var health_q: int = EntityRecord.HEALTH_Q_FULL
## Health, max health, state bits ([constant NetMessages.STATUS_IN_COMBAT] and company) and respawn
## tick of the own snapshot's extra block.
var health: int = DEFAULT_HEALTH
var max_health: int = DEFAULT_HEALTH
var status: int = 0
var respawn_tick: int = 0
## Action byte of the network record ([method ActionWire.encode]); 0 = no data.
var action: int = 0
## NPC: id of its definition in the NPC catalog, which travels in its ENTITY_SPAWN so the client
## picks the model, tabard and boss bar (0 = no definition).
var npc_def_id: int = 0
## STRUCTURE: id of its definition (ASCII, that of [member FortressDefinition.id]) and the live state of the
## fortress, which the [code]FortressController[/code] keeps up to date. Its ENTITY_SPAWN carries the full
## state at the time of addition.
var definition_id: String = ""
var fortress_state: FortressState = null
## PLAYER (protocol 7, docs/progression.md §7.3): character level (1 to 40; 0 = no progress, like a fake
## player) and the 8 B of its [CharacterAppearance] (empty = no appearance). Set by progress on spawn and on
## leveling up; they travel in its ENTITY_SPAWN (the level, only toward its realm: see [method encode_spawn]).
var level: int = 0
var appearance: PackedByteArray = PackedByteArray()


## Global position of the entity (the feet, if it is a player).
func get_position() -> Vector3:
	if not is_instance_valid(node):
		return Vector3.ZERO
	return node.global_position if node.is_inside_tree() else node.position


## The entity's [PlayerCharacter], or null if it is not a player.
func get_character() -> PlayerCharacter:
	return node as PlayerCharacter if is_instance_valid(node) else null


## Updates what snapshots show of the entity's health: [param new_health] and
## [param new_max_health] (the record's quantized health comes from them), the bits of
## [param new_status] and the respawn tick ([param new_respawn_tick], 0 if alive).
func set_health_view(new_health: int, new_max_health: int, new_status: int,
		new_respawn_tick: int) -> void:
	health = new_health
	max_health = new_max_health
	status = new_status
	respawn_tick = new_respawn_tick
	health_q = EntityRecord.quantize_health(new_health, new_max_health)


## Writes the entity's record (21 B, [constant EntityRecord.SIZE]) into [param bytes] starting at
## [param offset], without creating objects if it is a player. Grows the buffer if needed.
func encode_record(bytes: PackedByteArray, offset: int) -> void:
	var character: PlayerCharacter = get_character()
	if character != null:
		EntityRecord.encode_character(bytes, offset, net_id, character, teleport_counter, action,
				health_q)
		return
	# Entities without a character (simple NPCs): the node's position and turn, no velocity.
	var record := EntityRecord.new()
	record.net_id = net_id
	record.kind = kind
	record.position = get_position()
	record.yaw = node.rotation.y if is_instance_valid(node) else 0.0
	var teleport_bits: int = teleport_counter & EntityRecord.TELEPORT_MASK
	record.flags = (teleport_bits << EntityRecord.TELEPORT_SHIFT) | EntityRecord.FLAG_GROUNDED
	record.health_q = health_q
	record.action = action
	record.encode_into(bytes, offset)


## ENTITY_SPAWN message of the entity with its current state, given as the state "after
## [param tick]". [param for_owner] sets the "this is your character" bit (the own SPAWN), which carries the whole
## [PlayerState]; that of another's entity carries only what its 21 B record already shows
## (position, velocity, turn, ground, action, the two weapons and the active slot): not its exact
## stamina, exhaustion, parry cooldown, buffer, controls, held buttons,
## cooldowns, charges or movement effects (docs/combate.md, sections 1 and 6, and
## docs/abilities.md, section 5.2).
## [br][br]
## A player also carries their appearance and level (protocol 7, docs/progression.md §7.3); the real level only
## if it is the own SPAWN or [param receiver_realm] (the [enum NetProtocol.Realm] code of the receiver) is
## the entity's, and 0 if not: the enemy's level does not cross over (social.md §1). That is why whoever distributes SPAWNs
## encodes them per receiving realm.
func encode_spawn(tick: int, for_owner: bool, receiver_realm: int = NetProtocol.Realm.NONE) -> PackedByteArray:
	if kind == NetProtocol.EntityKind.STRUCTURE:
		if fortress_state == null:
			return PackedByteArray()
		return NetMessages.EntitySpawn.for_fortress(net_id, tick, definition_id,
				fortress_state).encode()
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = kind
	spawn.spawn_tick = tick
	spawn.realm = realm
	spawn.is_yours = for_owner
	spawn.teleport_counter = teleport_counter & EntityRecord.TELEPORT_MASK
	spawn.is_staff = is_staff
	spawn.display_name = display_name
	spawn.npc_def_id = npc_def_id
	if kind == NetProtocol.EntityKind.PLAYER:
		spawn.appearance = appearance
		spawn.level = level if for_owner or (receiver_realm == realm and realm != NetProtocol.Realm.NONE) else 0
	var character: PlayerCharacter = get_character()
	if character != null:
		spawn.state = character.get_state()
		if not for_owner:
			_hide_private_state(spawn.state)
	else:
		var state := PlayerState.new()
		state.position = get_position()
		state.yaw = PlayerState.to_f32(node.rotation.y) if is_instance_valid(node) else 0.0
		state.grounded = true
		spawn.state = state
	return spawn.encode()


# Leaves in [param state] only the public part of another's character: combat goes back to the weapons'
# initial values (full stamina, no flags, buffer, controls, parry, cooldowns,
# charges, consumable or movement slots) except the action in progress, which the 21 B record already
# shows, and the weapons: the other slot's and the active slot (bit 0 of combat_flags2) are visible
# (docs/abilities.md, section 5.2). The last tick's buttons and the jump counters are cleared.
static func _hide_private_state(state: PlayerState) -> void:
	var own: CombatState = state.combat
	var public := CombatState.initial(CombatCatalog.rules(), own.weapon_id, own.alt_weapon_id)
	public.combat_flags2 = own.combat_flags2 & CombatState.FLAG2_SECOND_SLOT
	public.action = own.action
	if own.action != CombatState.Action.NONE:
		public.action_id = own.action_id
		public.action_tick = own.action_tick
	state.combat = public
	state.prev_buttons = 0
	state.coyote_ticks = 0
	state.jump_buffer_ticks = 0
