class_name NetProtocol
extends RefCounted
## Constantes y utilidades del protocolo de red de la fase 2 (ver docs/red.md).
##
## Compartido: lo cargan el servidor y el cliente. Todo en ticks enteros a 60 Hz; nada de aquí lee
## el reloj ni depende de [code]scripts/client/[/code].

## Versión del protocolo. Cualquier cambio en los formatos o en la simulación la sube.
const PROTOCOL_VERSION: int = 2
## Primeros 4 bytes de los mensajes de autenticación (los bytes «ELDM»).
const MAGIC: int = 0x4D444C45
const DEFAULT_PORT: int = 24600
## Canales de transferencia propios (ver docs/red.md, sección 2). Van ligados a
## [constant PROTOCOL_VERSION].
const CUSTOM_CHANNELS: int = 3
## Canal de las entradas del cliente (no fiable, sin secuencia).
const CH_INPUT: int = 1
## Canal de los snapshots (no fiable, secuenciado).
const CH_SNAPSHOT: int = 2
## Canal de los mensajes fiables.
const CH_RELIABLE: int = 3
## Tamaño máximo de un paquete (bytes).
const MAX_PACKET_BYTES: int = 1200
## Ticks entre dos snapshots a un mismo cliente (30 Hz).
const SNAPSHOT_INTERVAL_TICKS: int = 2
const MAX_INPUTS_PER_BATCH: int = 8
const INPUT_REDUNDANCY: int = 4
const INPUT_REDUNDANCY_LOSSY: int = 8
## Cuántos ticks por delante del servidor se admite una entrada.
const MAX_INPUT_LEAD_TICKS: int = 30
## Ticks que el servidor repite el movimiento de la última entrada real antes de ponerlo a 0.
const REPEAT_MOVE_TICKS: int = 6
## Tope de la compensación de latencia (ticks).
const MAX_REWIND_TICKS: int = 24
## Valor de [code]input_margin[/code] cuando no hay datos.
const NO_MARGIN: int = -128
## Botones válidos de una entrada (bits 0-8). El servidor descarta el resto.
const VALID_BUTTONS: int = (1 << 9) - 1
const MAX_NAME_BYTES: int = 48
const MIN_NAME_CHARS: int = 3
const MAX_NAME_CHARS: int = 24
const MAX_TICKET_BYTES: int = 256
const MAX_ZONE_ID_BYTES: int = 32

# Tipos de mensaje (byte 0 de lo que va por send_bytes).
const MSG_INPUT_BATCH: int = 0x01
const MSG_CLIENT_READY: int = 0x02
const MSG_CLIENT_LEAVE: int = 0x03
const MSG_DEBUG_COMMAND: int = 0x04
const MSG_RESPAWN_REQUEST: int = 0x05
const MSG_SNAPSHOT: int = 0x10
const MSG_ENTITY_SPAWN: int = 0x20
const MSG_ENTITY_DESPAWN: int = 0x21
const MSG_OBJECT_STATE: int = 0x22   # reservado (fase 4)
const MSG_ENTITY_EVENT: int = 0x23
const MSG_NOTICE: int = 0x30
const MSG_HANDOFF: int = 0x31        # reservado (fase 6)

# Comandos de depuración (byte 1 de un DEBUG_COMMAND, solo con --debug-commands). Los ids son
# fijos: no se reutilizan ni se reordenan (docs/combate.md, sección 6).
## Teletransportar al jugador (3 × f32 de posición).
const DEBUG_TELEPORT: int = 1
## Curar al jugador del todo.
const DEBUG_HEAL: int = 2
## Matar al jugador.
const DEBUG_KILL: int = 3
## Resistencia infinita (bit 2 de [code]combat_flags[/code]: la máquina de acciones no gasta).
const DEBUG_STAMINA_INF: int = 4
## Cambiar el arma equipada.
const DEBUG_SET_WEAPON: int = 5
## Crear un maniquí de entrenamiento.
const DEBUG_SPAWN_DUMMY: int = 6
## Nombre -> id de cada comando de depuración de red. El registro de comandos del servidor
## comprueba contra esta tabla que todo comando de red tiene un id fijo.
const DEBUG_COMMAND_IDS: Dictionary[StringName, int] = {
	&"teleport": DEBUG_TELEPORT,
	&"heal": DEBUG_HEAL,
	&"kill": DEBUG_KILL,
	&"stamina_inf": DEBUG_STAMINA_INF,
	&"set_weapon": DEBUG_SET_WEAPON,
	&"spawn_dummy": DEBUG_SPAWN_DUMMY,
}

## Reino en la red (independiente de cómo lo represente [Zones]; ver [NetZones]).
enum Realm { NONE = 0, VARDHEIM = 1, SOLMARCH = 2, ASKARRA = 3 }
enum EntityKind { NONE = 0, PLAYER = 1, NPC = 2, PROJECTILE = 3, STRUCTURE = 4 }
## Resultado de la autenticación: 0 es WELCOME y el resto son motivos de REJECT.
enum Result { OK = 0, VERSION = 1, SIM_HASH = 2, REALM = 3, FULL = 4, TICKET = 5, MALFORMED = 6,
		TOO_MANY_CONNECTIONS = 7, NAME = 8 }
enum DespawnReason { OUT_OF_INTEREST = 0, DISCONNECTED = 1, DEATH = 2, HANDOFF = 3 }
enum NoticeCode { INFO = 0, KICK = 1, SHUTDOWN = 2 }

## Nombre de la cápsula que cuelga del personaje y entra en el [method compute_sim_hash].
const _COLLISION_NODE: NodePath = ^"Collision"


## Canal por el que viaja un mensaje de tipo [param msg_type] (el byte 0). Las entradas van por el
## canal de entradas y los snapshots por el suyo; todo lo demás (incluidos ENTITY_EVENT y
## RESPAWN_REQUEST) y los tipos desconocidos o reservados, por el canal fiable.
static func channel_for_type(msg_type: int) -> int:
	match msg_type:
		MSG_INPUT_BATCH:
			return CH_INPUT
		MSG_SNAPSHOT:
			return CH_SNAPSHOT
		MSG_ENTITY_EVENT, MSG_RESPAWN_REQUEST:
			return CH_RELIABLE
	return CH_RELIABLE


## Modo de transferencia de [param channel].
static func transfer_mode(channel: int) -> MultiplayerPeer.TransferMode:
	match channel:
		CH_INPUT:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		CH_SNAPSHOT:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


## true si [param channel] pierde paquetes (los canales de entradas y de snapshots).
static func is_unreliable_channel(channel: int) -> bool:
	return channel == CH_INPUT or channel == CH_SNAPSHOT


## Huella (u32) de todo lo que hace que la simulación de un cliente difiera de la del servidor:
## si no coincide, el servidor rechaza al cliente (REJECT SIM_HASH), porque predeciría mal todo
## el tiempo. Es el SHA-256 ([HashingContext]) de [code]var_to_bytes()[/code] de un array con la
## versión del protocolo, los ticks de física por segundo, el nombre del motor de física, los
## [code]@export[/code] de [PlayerCharacter] ordenados por nombre, los valores [code]floor_*[/code]
## que fija su [code]_ready()[/code] y el radio, la altura y la posición de la cápsula del nodo
## [code]Collision[/code], más la huella de la parte predicha del catálogo de combate
## ([method CombatCatalog.prediction_hash]). Se toman los 4 primeros bytes como u32.
## [br][br]
## La instancia debe estar en el árbol (o al menos haber pasado por [code]_ready()[/code]).
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
		capsule, CombatCatalog.prediction_hash(),
	]
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(summary))
	return context.finish().decode_u32(0)


## Entrada neutra: movimiento 0, botones 0, [code]look_yaw[/code] igual al yaw cuantizado y pitch 0.
## Ya está cuantizada (es lo que decodifica el servidor), así que sirve tal cual para la
## sustitución de entradas y el avance neutro del cliente.
static func neutral_input(tick: int, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input.quantized()


## Nombre del reino para mostrarlo: «Vardheim», «Solmarch», «Askarra» (de [RealmCatalog]) o
## «Ninguno» si [param realm] no es un reino jugable.
static func realm_display_name(realm: int) -> String:
	var id: StringName = RealmCatalog.id_of_code(realm)
	if RealmCatalog.is_realm(id):
		return RealmCatalog.display_name(id)
	return "Ninguno"


## Motivo de un rechazo de la autenticación, en español, para mostrarlo al jugador.
static func result_text(result: int) -> String:
	match result:
		Result.OK:
			return "Conexión aceptada"
		Result.VERSION:
			return "Versión del juego incompatible: actualiza el cliente"
		Result.SIM_HASH:
			return "La simulación del cliente no coincide con la del servidor"
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
	return "Conexión rechazada"
