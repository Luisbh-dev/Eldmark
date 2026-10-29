class_name NetEntity
extends RefCounted
## Entidad replicada por el servidor (docs/red.md, sección 9.1): un jugador (y, desde la fase 4,
## PNJ, proyectiles y estructuras).
## [br][br]
## Guarda lo que hace falta para replicarla: el id de red que asigna [NetEntityRegistry], el
## tipo, el reino, el tick de alta, el peer dueño, el nombre, los flags, su nodo y el contador de
## teletransporte. Sabe escribir su registro del snapshot sin crear objetos
## ([method encode_record]) y su mensaje ENTITY_SPAWN ([method encode_spawn]).

## La ven todos los jugadores de la zona, sin pasar por la [InterestPolicy] (fortalezas, puertas).
const FLAG_ALWAYS_RELEVANT: int = 1 << 0

## Id de red (1..65535) que asigna [NetEntityRegistry].
var net_id: int
## [enum NetProtocol.EntityKind].
var kind: int
## Código de [enum NetProtocol.Realm].
var realm: int
## Tick en el que se dio de alta.
var spawn_tick: int
## Id del peer dueño (0 si no lo controla ningún cliente).
var owner_peer: int = 0
var display_name: String
## Combinación de [constant FLAG_ALWAYS_RELEVANT].
var flags: int = 0
## Nodo de la entidad en el mundo del servidor: un [PlayerCharacter] si es un jugador.
var node: Node3D
## Sube (módulo 4) con cada teletransporte, para que el cliente no interpole el salto.
var teleport_counter: int = 0


## Posición global de la entidad (los pies, si es un jugador).
func get_position() -> Vector3:
	if not is_instance_valid(node):
		return Vector3.ZERO
	return node.global_position if node.is_inside_tree() else node.position


## El [PlayerCharacter] de la entidad, o null si no es un jugador.
func get_character() -> PlayerCharacter:
	return node as PlayerCharacter if is_instance_valid(node) else null


## Escribe el registro de la entidad (20 B, [constant EntityRecord.SIZE]) en [param bytes] a
## partir de [param offset], sin crear objetos si es un jugador. Amplía el búfer si hace falta.
func encode_record(bytes: PackedByteArray, offset: int) -> void:
	var character: PlayerCharacter = get_character()
	if character != null:
		EntityRecord.encode_character(bytes, offset, net_id, character, teleport_counter, 0)
		return
	# Entidades sin personaje (PNJ simples): posición y giro del nodo, sin velocidad.
	var record := EntityRecord.new()
	record.net_id = net_id
	record.kind = kind
	record.position = get_position()
	record.yaw = node.rotation.y if is_instance_valid(node) else 0.0
	var teleport_bits: int = teleport_counter & EntityRecord.TELEPORT_MASK
	record.flags = (teleport_bits << EntityRecord.TELEPORT_SHIFT) | EntityRecord.FLAG_GROUNDED
	record.encode_into(bytes, offset)


## Mensaje ENTITY_SPAWN de la entidad con su estado actual, que se da como el estado «tras
## [param tick]». [param for_owner] pone el bit «es tu personaje» (el SPAWN propio).
func encode_spawn(tick: int, for_owner: bool) -> PackedByteArray:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = kind
	spawn.spawn_tick = tick
	spawn.realm = realm
	spawn.is_yours = for_owner
	spawn.teleport_counter = teleport_counter & EntityRecord.TELEPORT_MASK
	spawn.display_name = display_name
	var character: PlayerCharacter = get_character()
	if character != null:
		spawn.state = character.get_state()
	else:
		var state := PlayerState.new()
		state.position = get_position()
		state.yaw = PlayerState.to_f32(node.rotation.y) if is_instance_valid(node) else 0.0
		state.grounded = true
		spawn.state = state
	return spawn.encode()
