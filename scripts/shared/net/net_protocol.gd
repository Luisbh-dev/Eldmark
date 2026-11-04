class_name NetProtocol
extends RefCounted
## Constants and utilities of the phase 2 network protocol (see docs/networking.md).
##
## Shared: loaded by the server and the client. Everything in integer ticks at 60 Hz; nothing here reads
## the clock or depends on [code]scripts/client/[/code].

## Protocol version. Any change to the formats or the simulation bumps it.
## [br]- 2: phase 3 combat (docs/combate.md).
## [br]- 3: phase 3 review (the action machine and air movement change the predicted
## simulation: bit 6 of [code]combat_flags[/code], charge canceled after silence, combo reset).
## [br]- 4: phase 4 fortress (docs/fortress.md, section 2): OBJECT_STATE, ENTITY_SPAWN of
## structures and of NPCs with a definition, ENTITY_EVENT WAR and TELEGRAPH, UNSTUCK_REQUEST, SCOREBOARD, the
## REJECT IMBALANCE, the per-realm count in the WELCOME and debug commands 7 to 12.
## [br]- 5: chat and parties (SOC-03, SOC-06): CHAT_SEND and CHAT_MESSAGE (0x40 and 0x41) and the PARTY_* (0x48
## onward), all over the reliable channel (docs/social.md, section 12).
## [br]- 6: abilities, effects, weapon swap, projectiles, knocked down and templates (docs/abilities.md,
## section 5): 111 B [PlayerState], buttons 9 to 12 in [constant VALID_BUTTONS], LOADOUT_SELECT (0x07),
## debug commands 13 to 16, the ENTITY_SPAWN and the ENTITY_DESPAWN reasons for projectiles,
## ENTITY_EVENT 7 to 11, bits 5 and 6 of a HIT, bit 3 of the record flags (slot 2 active)
## and bit 3 of [code]status[/code] (knocked down).
## [br]- 7: phase 5 (docs/platform.md and docs/progression.md): REJECT 10–12, 52 B ticket, [code]auth_timeout[/code]
## of 10 s, bit 3 of the [code]flags[/code] of the ENTITY_SPAWN header (game staff), +9 B in the PLAYER
## SPAWN (level and appearance), messages 0x50–0x55, ENTITY_EVENT 16 LEVEL_UP, DEBUG_COMMAND 40–43 and
## [code]ItemDatabase[/code] in the [code]sim_hash[/code].
const PROTOCOL_VERSION: int = 7
## First 4 bytes of authentication messages (the bytes "ELDM").
const MAGIC: int = 0x4D444C45
const DEFAULT_PORT: int = 24600
## Own transfer channels (see docs/networking.md, section 2). Tied to
## [constant PROTOCOL_VERSION].
const CUSTOM_CHANNELS: int = 3
## Channel for client inputs (unreliable, unsequenced).
const CH_INPUT: int = 1
## Channel for snapshots (unreliable, sequenced).
const CH_SNAPSHOT: int = 2
## Channel for reliable messages.
const CH_RELIABLE: int = 3
## Maximum size of a packet (bytes).
const MAX_PACKET_BYTES: int = 1200
## Ticks between two snapshots to the same client (30 Hz).
const SNAPSHOT_INTERVAL_TICKS: int = 2
const MAX_INPUTS_PER_BATCH: int = 8
const INPUT_REDUNDANCY: int = 4
const INPUT_REDUNDANCY_LOSSY: int = 8
## How many ticks ahead of the server an input is accepted.
const MAX_INPUT_LEAD_TICKS: int = 30
## Ticks the server repeats the movement of the last real input before setting it to 0.
const REPEAT_MOVE_TICKS: int = 6
## Client interpolation delay in the INPUT_BATCH: ticks × [constant INTERP_DELAY_Q_SCALE].
## Its real maximum is that of the client's interpolation clock (12 ticks); the server clamps whatever
## arrives above it and counts it as a warning.
const INTERP_DELAY_Q_SCALE: int = 8
const MAX_INTERP_DELAY_TICKS: int = 12
const MAX_INTERP_DELAY_Q: int = MAX_INTERP_DELAY_TICKS * INTERP_DELAY_Q_SCALE
## Cap on lag compensation (ticks).
const MAX_REWIND_TICKS: int = 24
## Value of [code]input_margin[/code] when there is no data.
const NO_MARGIN: int = -128
## Valid buttons of an input (bits 0-12, since protocol 6: [code]SWAP_WEAPON[/code],
## [code]AIM_LEFT[/code], [code]CONSUMABLE_1[/code] and [code]CONSUMABLE_2[/code] of [PlayerInput]). The server
## discards the rest: bits 13-14 are reserved and 15 is the substituted mark.
const VALID_BUTTONS: int = (1 << 13) - 1
const MAX_NAME_BYTES: int = 48
const MIN_NAME_CHARS: int = 3
const MAX_NAME_CHARS: int = 24
const MAX_TICKET_BYTES: int = 256
const MAX_ZONE_ID_BYTES: int = 32
## Maximum bytes of the (ASCII) id of a structure's definition in its ENTITY_SPAWN.
const MAX_DEFINITION_ID_BYTES: int = 32

# Message types (byte 0 of what goes through send_bytes).
const MSG_INPUT_BATCH: int = 0x01
const MSG_CLIENT_READY: int = 0x02
const MSG_CLIENT_LEAVE: int = 0x03
const MSG_DEBUG_COMMAND: int = 0x04
const MSG_RESPAWN_REQUEST: int = 0x05
## /atascado request (C→S, phase 4).
const MSG_UNSTUCK_REQUEST: int = 0x06
## Equipment template chosen for the next spawn (C→S, protocol 6; docs/abilities.md, section
## 5.1). Valid from the WELCOME, also before CLIENT_READY.
const MSG_LOADOUT_SELECT: int = 0x07
const MSG_SNAPSHOT: int = 0x10
const MSG_ENTITY_SPAWN: int = 0x20
const MSG_ENTITY_DESPAWN: int = 0x21
## Replicated state of an object (S→C, phase 4): individual fields of a structure.
const MSG_OBJECT_STATE: int = 0x22
const MSG_ENTITY_EVENT: int = 0x23
const MSG_NOTICE: int = 0x30
const MSG_HANDOFF: int = 0x31        # reserved (phase 6)
## Zone scoreboard (S→C, phase 4).
const MSG_SCOREBOARD: int = 0x32
## Player chat message (C→S, protocol 5): channel, recipient if it is a whisper, and text.
const MSG_CHAT_SEND: int = 0x40
## Chat message distributed by the server (S→C, protocol 5): channel, sender, recipient and text.
const MSG_CHAT_MESSAGE: int = 0x41
## Parties (protocol 5, SOC-06). C→S: invite a player of your realm, respond to an invitation, leave,
## kick a member and hand over leadership.
const MSG_PARTY_INVITE: int = 0x48
const MSG_PARTY_RESPONSE: int = 0x49
const MSG_PARTY_LEAVE: int = 0x4A
const MSG_PARTY_KICK: int = 0x4B
const MSG_PARTY_LEADER: int = 0x4C
## Parties (S→C): an invitation received or no longer valid, the member list (when it changes) and the
## compact state of the members (health, stamina and position, at 2 Hz).
const MSG_PARTY_INVITATION: int = 0x4D
const MSG_PARTY_ROSTER: int = 0x4E
const MSG_PARTY_STATUS: int = 0x4F
## Maximum members of a party (docs/social.md, section 3). The party belongs to the same realm and the member
## list and compact state always fit in one packet.
const PARTY_MAX_SIZE: int = 5
## Inventory and progress (protocol 7, docs/progression.md §4.6 and §12; formats in [ProgressMessages]), all over
## the reliable channel. C→S: an inventory request (move, split or destroy) and the sync request. S→C,
## only to the owner: the slot delta, the whole inventory in pages, a balance and the level with its XP. 0x56
## through 0x5F are reserved (bank, trade and mail from phase 6).
const MSG_INVENTORY_REQUEST: int = 0x50
const MSG_INVENTORY_DELTA: int = 0x51
const MSG_INVENTORY_FULL: int = 0x52
const MSG_INVENTORY_SYNC_REQUEST: int = 0x53
const MSG_WALLET_UPDATE: int = 0x54
const MSG_PROGRESS_UPDATE: int = 0x55

# Debug commands (byte 1 of a DEBUG_COMMAND, only with --debug-commands). The ids are
# fixed: they are not reused or reordered (docs/combate.md, section 6).
## Teleport the player (3 × f32 of position).
const DEBUG_TELEPORT: int = 1
## Fully heal the player.
const DEBUG_HEAL: int = 2
## Kill the player.
const DEBUG_KILL: int = 3
## Infinite stamina (bit 2 of [code]combat_flags[/code]: the action machine does not spend).
const DEBUG_STAMINA_INF: int = 4
## Change the equipped weapon.
const DEBUG_SET_WEAPON: int = 5
## Create a training dummy.
const DEBUG_SPAWN_DUMMY: int = 6
## /atascado (phase 4, docs/fortress.md section 5). The player command goes through its own message
## ([constant MSG_UNSTUCK_REQUEST]); the id remains reserved. No data.
const DEBUG_UNSTUCK: int = 7
## Return the fortress to neutral. No data.
const DEBUG_FORT_RESET: int = 8
## Give the fortress to a realm (1 B: realm code from 0 to 3).
const DEBUG_FORT_OWNER: int = 9
## Kill the fortress captain. No data.
const DEBUG_FORT_KILL_CAPTAIN: int = 10
## Multiply the capture speed (1 B: factor from 1 to 255).
const DEBUG_FORT_CAPTURE_SPEED: int = 11
## Turn the NPC debug log on or off (1 B: 0 or 1).
const DEBUG_NPC_DEBUG: int = 12
## Abilities with no cooldown (protocol 6; 1 B: 0 off, 1 on). It is bit 7 of
## [code]combat_flags2[/code]: the machine sets no cooldowns and spends no charges.
const DEBUG_COOLDOWNS_OFF: int = 13
## Apply a status effect to oneself (protocol 6; 3 B: [code]u8 status_id[/code] from the catalog, from 1 to 255, and
## [code]u16[/code] ticks of duration, 0 = those from the data).
const DEBUG_APPLY_STATUS: int = 14
## Knock oneself down as if an enemy had knocked you down, with no author (protocol 6). No data.
const DEBUG_DOWN: int = 15
## Refill the template's consumable charges (protocol 6). No data.
const DEBUG_REFILL: int = 16
## Progression GM commands via DEBUG_COMMAND (protocol 7, docs/progression.md §10), always on the
## player themselves. Give oneself an object (4 B: [code]u16[/code] net id from [ItemDatabase], from 1 onward, and
## [code]u16[/code] quantity, from 1 to 999).
const DEBUG_ITEM_GIVE: int = 40
## Add or subtract a currency (5 B: [code]u8[/code] currency, 1 gold or 2 merits, and [code]s32[/code] nonzero
## amount). The operation's [code]note[/code] is "debug".
const DEBUG_CURRENCY_ADD: int = 41
## Set the level (1 B: from 1 to [constant ProgressMessages.MAX_LEVEL]).
const DEBUG_LEVEL_SET: int = 42
## Add XP (4 B: [code]u32[/code] from 1 to 10,000,000).
const DEBUG_XP_ADD: int = 43
## Name -> id of each network debug command. The server's command registry
## checks against this table that every network command has a fixed id.
const DEBUG_COMMAND_IDS: Dictionary[StringName, int] = {
	&"teleport": DEBUG_TELEPORT,
	&"heal": DEBUG_HEAL,
	&"kill": DEBUG_KILL,
	&"stamina_inf": DEBUG_STAMINA_INF,
	&"set_weapon": DEBUG_SET_WEAPON,
	&"spawn_dummy": DEBUG_SPAWN_DUMMY,
	&"unstuck": DEBUG_UNSTUCK,
	&"fort_reset": DEBUG_FORT_RESET,
	&"fort_owner": DEBUG_FORT_OWNER,
	&"fort_kill_captain": DEBUG_FORT_KILL_CAPTAIN,
	&"fort_capture_speed": DEBUG_FORT_CAPTURE_SPEED,
	&"npc_debug": DEBUG_NPC_DEBUG,
	&"cooldowns_off": DEBUG_COOLDOWNS_OFF,
	&"apply_status": DEBUG_APPLY_STATUS,
	&"down": DEBUG_DOWN,
	&"refill": DEBUG_REFILL,
	&"item_give": DEBUG_ITEM_GIVE,
	&"currency_add": DEBUG_CURRENCY_ADD,
	&"level_set": DEBUG_LEVEL_SET,
	&"xp_add": DEBUG_XP_ADD,
}

## Realm on the network (independent of how [Zones] represents it; see [NetZones]).
enum Realm { NONE = 0, VARDHEIM = 1, SOLMARCH = 2, ASKARRA = 3 }
enum EntityKind { NONE = 0, PLAYER = 1, NPC = 2, PROJECTILE = 3, STRUCTURE = 4 }
## Authentication result: 0 is WELCOME and the rest are REJECT reasons.
## Since protocol 7 (docs/platform.md §5.4): BUSY, the character is still in the world (in another zone or leaving
## in combat); UNAVAILABLE, the platform does not respond, the zone is fenced off or the character could not be loaded; and
## BANNED, the account is suspended, banned or has deletion requested (the text is composed by the platform).
enum Result { OK = 0, VERSION = 1, SIM_HASH = 2, REALM = 3, FULL = 4, TICKET = 5, MALFORMED = 6,
		TOO_MANY_CONNECTIONS = 7, NAME = 8, IMBALANCE = 9, BUSY = 10, UNAVAILABLE = 11, BANNED = 12 }
## Reason for an ENTITY_DESPAWN. IMPACT and EXPIRED belong to projectiles (protocol 6): the arrow hit
## something at [code]despawn_tick[/code], or expired (or was removed by the server: arrow cap, the
## shooter left).
enum DespawnReason { OUT_OF_INTEREST = 0, DISCONNECTED = 1, DEATH = 2, HANDOFF = 3, IMPACT = 4,
		EXPIRED = 5 }
enum NoticeCode { INFO = 0, KICK = 1, SHUTDOWN = 2 }

## Name of the capsule that hangs from the character and goes into the [method compute_sim_hash].
const _COLLISION_NODE: NodePath = ^"Collision"


## Channel over which a message of type [param msg_type] (byte 0) travels. Inputs go over the
## input channel and snapshots over theirs; everything else (including ENTITY_EVENT,
## RESPAWN_REQUEST, UNSTUCK_REQUEST, LOADOUT_SELECT, OBJECT_STATE, SCOREBOARD, chat, parties and, since
## protocol 7, inventory and progress) and unknown or reserved types, over the reliable channel.
static func channel_for_type(msg_type: int) -> int:
	match msg_type:
		MSG_INPUT_BATCH:
			return CH_INPUT
		MSG_SNAPSHOT:
			return CH_SNAPSHOT
		MSG_ENTITY_EVENT, MSG_RESPAWN_REQUEST, MSG_UNSTUCK_REQUEST, MSG_LOADOUT_SELECT, MSG_OBJECT_STATE, \
				MSG_SCOREBOARD, MSG_CHAT_SEND, MSG_CHAT_MESSAGE, MSG_PARTY_INVITE, MSG_PARTY_RESPONSE, \
				MSG_PARTY_LEAVE, MSG_PARTY_KICK, MSG_PARTY_LEADER, MSG_PARTY_INVITATION, \
				MSG_PARTY_ROSTER, MSG_PARTY_STATUS, MSG_INVENTORY_REQUEST, MSG_INVENTORY_DELTA, \
				MSG_INVENTORY_FULL, MSG_INVENTORY_SYNC_REQUEST, MSG_WALLET_UPDATE, MSG_PROGRESS_UPDATE:
			return CH_RELIABLE
	return CH_RELIABLE


## Transfer mode of [param channel].
static func transfer_mode(channel: int) -> MultiplayerPeer.TransferMode:
	match channel:
		CH_INPUT:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		CH_SNAPSHOT:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


## true if [param channel] loses packets (the input and snapshot channels).
static func is_unreliable_channel(channel: int) -> bool:
	return channel == CH_INPUT or channel == CH_SNAPSHOT


## Fingerprint (u32) of the simulation and of the catalogs whose ids travel: if it does not match, the server rejects the
## client (REJECT SIM_HASH), because it would predict wrongly all the time or misread the ids. It is the SHA-256
## ([HashingContext]) of [code]var_to_bytes()[/code] of an array with the protocol version, the physics ticks
## per second, the physics engine name, the [code]@export[/code]s of [PlayerCharacter] sorted by
## name, the [code]floor_*[/code] values that its [code]_ready()[/code] sets and the radius, height and position
## of the capsule of the [code]Collision[/code] node, plus the fingerprint of the predicted part of the combat catalog
## ([method CombatCatalog.prediction_hash]) and, since protocol 7, that of the item database
## ([method ItemDatabase.wire_hash]: object net ids travel to the owner; docs/progression.md §2.2 and §12). The
## appearance is not included: an unknown index already falls back to the default one. The first 4 bytes are taken as a u32.
## [br][br]
## The instance must be in the tree (or at least have gone through [code]_ready()[/code]).
static func compute_sim_hash(character: PlayerCharacter) -> int:
	var exports: Array = []
	var properties: Array[Dictionary] = character.get_property_list()
	properties.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]) < String(b["name"]))
	var wanted_usage: int = PROPERTY_USAGE_SCRIPT_VARIABLE | PROPERTY_USAGE_EDITOR
	for property: Dictionary in properties:
		if (int(property["usage"]) & wanted_usage) == wanted_usage:
			var property_name: String = property["name"]
			exports.append([property_name, character.get(property_name)])

	var floor_values: Array = [
		character.floor_max_angle, character.floor_snap_length,
		character.floor_constant_speed, character.floor_stop_on_slope,
	]

	var capsule: Array = []
	var collision: CollisionShape3D = \
			character.get_node_or_null(_COLLISION_NODE) as CollisionShape3D
	if collision != null:
		capsule.append(collision.position)
		var shape: CapsuleShape3D = collision.shape as CapsuleShape3D
		if shape != null:
			capsule.append(shape.radius)
			capsule.append(shape.height)

	var physics_engine: String = str(ProjectSettings.get_setting("physics/3d/physics_engine", ""))
	var summary: Array = [
		PROTOCOL_VERSION, Engine.physics_ticks_per_second, physics_engine, exports, floor_values,
		capsule, CombatCatalog.prediction_hash(), ItemDatabase.shared().wire_hash(),
	]
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(summary))
	return context.finish().decode_u32(0)


## Neutral input: movement 0, buttons 0, [code]look_yaw[/code] equal to the quantized yaw and pitch 0.
## It is already quantized (it is what the server decodes), so it works as is for
## input substitution and the client's neutral advance.
static func neutral_input(tick: int, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input.quantized()


## Name of the realm for display: "Vardheim", "Solmarch", "Askarra" (from [RealmCatalog]) or
## "Ninguno" (none) if [param realm] is not a playable realm.
static func realm_display_name(realm: int) -> String:
	var id: StringName = RealmCatalog.id_of_code(realm)
	if RealmCatalog.is_realm(id):
		return RealmCatalog.display_name(id)
	return "Ninguno"


## Reason for an authentication rejection, in Spanish, to show to the player.
static func result_text(result: int) -> String:
	match result:
		Result.OK:
			return "Conexión aceptada"
		Result.VERSION:
			return "Versión del juego incompatible: actualiza el cliente"
		Result.SIM_HASH:
			# Since protocol 7 the fingerprint also covers the catalogs whose ids travel (docs/progression.md §12).
			return "Los datos del juego no coinciden con los del servidor: actualiza el cliente"
		Result.REALM:
			return "Reino no válido o no admitido en esta zona"
		Result.FULL:
			return "Servidor lleno"
		Result.TICKET:
			return "Billete de acceso no válido o caducado"
		Result.MALFORMED:
			return "Mensaje de conexión mal formado"
		Result.TOO_MANY_CONNECTIONS:
			return "Demasiadas conexiones desde tu dirección"
		Result.NAME:
			return "Nombre no válido o ya en uso: " + NameRules.rules_summary()
		Result.IMBALANCE:
			return "Ese reino tiene demasiados jugadores en esta zona: elige otro para " \
					+ "equilibrar la batalla"
		Result.BUSY:
			return "Tu personaje sigue en el mundo: espera unos segundos"
		Result.UNAVAILABLE:
			return "El servicio de cuentas no responde: inténtalo más tarde"
		Result.BANNED:
			# The real text is composed by the platform (the message of the 403 account_blocked); this one only appears
			# if it is missing.
			return "Tu cuenta está suspendida"
	return "Conexión rechazada"
