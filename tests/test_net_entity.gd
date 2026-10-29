extends TestCase
## Pruebas de [NetEntity]: el registro del snapshot y el mensaje ENTITY_SPAWN de una entidad de
## red (docs/red.md, sección 9.1).

const PLAYER: int = NetProtocol.EntityKind.PLAYER

var _nodes: Array[Node] = []


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.is_inside_tree():
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _make_player(position: Vector3 = Vector3(12.34, 5.0, -8.76), yaw: float = 1.25) -> NetEntity:
	var registry := NetEntityRegistry.new()
	var entity: NetEntity = registry.allocate(PLAYER, 40)
	var character := PlayerCharacter.new()
	_nodes.append(character)
	character.position = position
	character.yaw = yaw
	character.velocity = Vector3(1.5, -2.0, 3.25)
	character.grounded = true
	character.prev_buttons = PlayerInput.JUMP
	character.last_input_tick = 39
	entity.node = character
	entity.realm = NetProtocol.Realm.SOLMARCH
	entity.display_name = "Brunilda"
	entity.owner_peer = 17
	return entity


func test_get_character_and_position() -> void:
	var entity: NetEntity = _make_player()
	assert_not_null(entity.get_character(), "un jugador tiene personaje")
	assert_vec_near(entity.get_position(), Vector3(12.34, 5.0, -8.76), 1e-5,
			"posición fuera del árbol")

	var plain := Node3D.new()
	_nodes.append(plain)
	plain.position = Vector3(1, 2, 3)
	var npc := NetEntity.new()
	npc.kind = NetProtocol.EntityKind.NPC
	npc.node = plain
	assert_null(npc.get_character(), "un nodo cualquiera no es un jugador")
	assert_vec_near(npc.get_position(), Vector3(1, 2, 3), 1e-6, "posición del nodo")

	var empty := NetEntity.new()
	assert_null(empty.get_character(), "sin nodo")
	assert_vec_near(empty.get_position(), Vector3.ZERO, 1e-6, "sin nodo, el origen")


func test_position_is_global_when_in_the_tree() -> void:
	var parent := Node3D.new()
	_nodes.append(parent)
	tree.root.add_child(parent)
	parent.position = Vector3(100, 0, 0)
	var entity: NetEntity = _make_player(Vector3(5, 0, 0))
	parent.add_child(entity.node)
	assert_vec_near(entity.get_position(), Vector3(105, 0, 0), 1e-4, "posición global")


func test_freed_node_is_handled() -> void:
	var entity: NetEntity = _make_player()
	entity.node.free()
	assert_null(entity.get_character(), "un nodo liberado ya no es un personaje")
	assert_vec_near(entity.get_position(), Vector3.ZERO, 1e-6, "ni tiene posición")


func test_encode_record_matches_the_shared_encoder() -> void:
	var entity: NetEntity = _make_player()
	entity.teleport_counter = 2
	var from_entity := PackedByteArray()
	entity.encode_record(from_entity, 0)
	var direct := PackedByteArray()
	EntityRecord.encode_character(direct, 0, entity.net_id, entity.get_character(), 2, 0)
	assert_eq(from_entity.size(), EntityRecord.SIZE, "20 B")
	assert_eq(from_entity, direct, "los mismos bytes que EntityRecord.encode_character")
	var record: EntityRecord = EntityRecord.decode_from(from_entity, 0, PLAYER)
	assert_eq(record.net_id, entity.net_id, "net_id")
	assert_vec_near(record.position, Vector3(12.34, 5.0, -8.76), 0.0087, "posición")
	assert_eq(record.get_teleport_counter(), 2, "contador de teletransporte")
	assert_true(record.is_grounded(), "grounded")
	assert_vec_near(record.velocity, Vector3(1.5, -2.0, 3.25), 0.0087, "velocidad")


func test_encode_record_at_an_offset_grows_the_buffer() -> void:
	var entity: NetEntity = _make_player()
	var bytes := PackedByteArray()
	bytes.resize(4)
	entity.encode_record(bytes, 40)
	assert_eq(bytes.size(), 60, "el búfer crece hasta caber el registro")
	assert_eq(bytes.decode_u16(40), entity.net_id, "net_id en el offset")
	var other: NetEntity = _make_player(Vector3(1, 1, 1))
	other.net_id = 777
	other.encode_record(bytes, 20)
	assert_eq(bytes.decode_u16(20), 777, "otro registro en otro offset")
	assert_eq(bytes.decode_u16(40), entity.net_id, "sin pisar el anterior")


func test_teleport_counter_wraps_modulo_four_in_the_record() -> void:
	var entity: NetEntity = _make_player()
	entity.teleport_counter = 5
	var bytes := PackedByteArray()
	entity.encode_record(bytes, 0)
	assert_eq(EntityRecord.decode_from(bytes, 0, PLAYER).get_teleport_counter(), 1, "5 mod 4")


func test_npc_record_without_character() -> void:
	var plain := Node3D.new()
	_nodes.append(plain)
	plain.position = Vector3(10, 0, 20)
	plain.rotation.y = 0.5
	var npc := NetEntity.new()
	npc.net_id = 9
	npc.kind = NetProtocol.EntityKind.NPC
	npc.node = plain
	var bytes := PackedByteArray()
	npc.encode_record(bytes, 0)
	var record: EntityRecord = EntityRecord.decode_from(bytes, 0, NetProtocol.EntityKind.NPC)
	assert_eq(record.net_id, 9, "net_id")
	assert_vec_near(record.position, Vector3(10, 0, 20), 0.0087, "posición")
	assert_near(record.yaw, 0.5, 1e-3, "yaw")
	assert_vec_near(record.velocity, Vector3.ZERO, 1e-6, "sin velocidad")
	assert_true(record.is_grounded(), "en el suelo")


func test_encode_spawn_for_other_players() -> void:
	var entity: NetEntity = _make_player()
	entity.teleport_counter = 1
	var message: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			entity.encode_spawn(123, false))
	if not assert_not_null(message, "el ENTITY_SPAWN se decodifica"):
		return
	assert_eq(message.net_id, entity.net_id, "net_id")
	assert_eq(message.kind, PLAYER, "kind")
	assert_eq(message.spawn_tick, 123, "spawn_tick es el tick del estado que se envía")
	assert_eq(message.realm, NetProtocol.Realm.SOLMARCH, "reino")
	assert_false(message.is_yours, "no es el personaje del receptor")
	assert_eq(message.teleport_counter, 1, "contador de teletransporte")
	assert_eq(message.display_name, "Brunilda", "nombre")
	if assert_not_null(message.state, "con el estado"):
		assert_eq(message.state.encode(), entity.get_character().get_state().encode(),
				"el PlayerState del personaje, completo")
		assert_eq(message.state.last_input_tick, 39, "incluido last_input_tick")
		assert_eq(message.state.prev_buttons, PlayerInput.JUMP, "e incluido prev_buttons")


func test_encode_spawn_for_the_owner_sets_the_flag() -> void:
	var entity: NetEntity = _make_player()
	var message: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			entity.encode_spawn(40, true))
	assert_true(message.is_yours, "el SPAWN propio lleva el bit «tuyo»")
	assert_eq(message.spawn_tick, 40, "tick 40")


func test_encode_spawn_keeps_names_within_the_limit() -> void:
	var entity: NetEntity = _make_player()
	entity.display_name = "ñ".repeat(40)
	var bytes: PackedByteArray = entity.encode_spawn(1, false)
	var message: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if assert_not_null(message, "se decodifica aunque el nombre sea largo"):
		assert_true(message.display_name.to_utf8_buffer().size() <= NetProtocol.MAX_NAME_BYTES,
				"nombre recortado a 48 B")


func test_encode_spawn_of_a_node_without_character() -> void:
	var plain := Node3D.new()
	_nodes.append(plain)
	plain.position = Vector3(3, 0, 4)
	var npc := NetEntity.new()
	npc.net_id = 12
	npc.kind = NetProtocol.EntityKind.NPC
	npc.realm = NetProtocol.Realm.NONE
	npc.display_name = "Guardia"
	npc.node = plain
	var message: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			npc.encode_spawn(8, false))
	if not assert_not_null(message, "se decodifica"):
		return
	assert_eq(message.kind, NetProtocol.EntityKind.NPC, "kind")
	assert_vec_near(message.state.position, Vector3(3, 0, 4), 1e-5, "posición")
	assert_eq(message.display_name, "Guardia", "nombre")


func test_always_relevant_flag() -> void:
	var entity: NetEntity = _make_player()
	assert_eq(entity.flags & NetEntity.FLAG_ALWAYS_RELEVANT, 0, "por defecto pasa por la política")
	entity.flags |= NetEntity.FLAG_ALWAYS_RELEVANT
	assert_true((entity.flags & NetEntity.FLAG_ALWAYS_RELEVANT) != 0, "se puede marcar")
	assert_eq(NetEntity.FLAG_ALWAYS_RELEVANT, 1, "bit 0")
