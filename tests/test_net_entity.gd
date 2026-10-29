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
	EntityRecord.encode_character(direct, 0, entity.net_id, entity.get_character(), 2, 0,
			EntityRecord.HEALTH_Q_FULL)
	assert_eq(from_entity.size(), EntityRecord.SIZE, "21 B")
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
	assert_eq(bytes.size(), 40 + EntityRecord.SIZE, "el búfer crece hasta caber el registro")
	assert_eq(bytes.decode_u16(40), entity.net_id, "net_id en el offset")
	var other: NetEntity = _make_player(Vector3(1, 1, 1))
	other.net_id = 777
	other.encode_record(bytes, 10)
	assert_eq(bytes.decode_u16(10), 777, "otro registro en otro offset")
	assert_eq(bytes.decode_u16(40), entity.net_id, "sin pisar el anterior")


func test_health_in_the_record_and_the_snapshot_block() -> void:
	var entity: NetEntity = _make_player()
	# Sin Combatant: sano y con la vida llena.
	assert_eq(entity.health_q, EntityRecord.HEALTH_Q_FULL, "vida cuantizada llena por defecto")
	assert_eq(entity.health, NetEntity.DEFAULT_HEALTH, "vida por defecto")
	assert_eq(entity.max_health, NetEntity.DEFAULT_HEALTH, "vida máxima por defecto")
	assert_eq(entity.status, 0, "sin estados")
	assert_eq(entity.respawn_tick, 0, "sin reaparición pendiente")
	var bytes := PackedByteArray()
	entity.encode_record(bytes, 0)
	assert_eq(EntityRecord.decode_from(bytes, 0, PLAYER).health_q, 255, "registro con health_q 255")

	# set_health_view cuantiza la vida en el registro y guarda el bloque extra.
	entity.set_health_view(250, 1000, NetMessages.STATUS_IN_COMBAT, 0)
	assert_eq(entity.health_q, EntityRecord.quantize_health(250, 1000), "health_q cuantizada")
	assert_eq(entity.health_q, 64, "250 de 1000: 63,75 hacia arriba = 64")
	assert_eq(entity.health, 250, "vida")
	assert_eq(entity.max_health, 1000, "vida máxima")
	assert_eq(entity.status, NetMessages.STATUS_IN_COMBAT, "estado")
	entity.encode_record(bytes, 0)
	assert_eq(EntityRecord.decode_from(bytes, 0, PLAYER).health_q, 64, "el registro lleva la vida")
	assert_eq(bytes.decode_u8(EntityRecord.SIZE - 1), 64, "health_q es el último byte del registro")

	# Muerto: 0 en el registro y tick de reaparición en el bloque.
	entity.set_health_view(0, 1000, NetMessages.STATUS_DEAD, 4321)
	assert_eq(entity.health_q, EntityRecord.HEALTH_Q_DEAD, "muerto: health_q 0")
	assert_eq(entity.respawn_tick, 4321, "tick de reaparición")
	entity.encode_record(bytes, 0)
	assert_eq(EntityRecord.decode_from(bytes, 0, PLAYER).health_q, 0, "el registro dice muerto")

	# Una entidad sin personaje lleva también la vida.
	var plain := Node3D.new()
	_nodes.append(plain)
	var npc := NetEntity.new()
	npc.net_id = 9
	npc.kind = NetProtocol.EntityKind.NPC
	npc.node = plain
	npc.set_health_view(500, 1000, 0, 0)
	var npc_bytes := PackedByteArray()
	npc.encode_record(npc_bytes, 0)
	assert_eq(EntityRecord.decode_from(npc_bytes, 0, NetProtocol.EntityKind.NPC).health_q, 128,
			"el PNJ lleva su vida: 127,5 hacia arriba = 128")


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
		var own: PlayerState = entity.get_character().get_state()
		assert_eq(message.state.position, own.position, "la posición, que ya viaja en el registro")
		assert_eq(message.state.velocity, own.velocity, "la velocidad")
		assert_eq(message.state.yaw, own.yaw, "el giro")
		assert_eq(message.state.grounded, own.grounded, "y si pisa suelo")
		assert_eq(message.state.last_input_tick, 39, "incluido last_input_tick")
		# R4: de lo ajeno no viaja nada que no esté ya en el registro de 21 B (ver la prueba siguiente).
		assert_eq(message.state.prev_buttons, 0, "los botones que mantiene no se envían")


## R4: el ENTITY_SPAWN de una entidad ajena no lleva el CombatState entero (resistencia exacta,
## agotamiento, enfriamiento de la parada, búfer y controles del enemigo); solo el propio, completo.
func test_encode_spawn_of_another_player_hides_the_private_combat_state() -> void:
	var entity: NetEntity = _make_player()
	var character: PlayerCharacter = entity.get_character()
	character.prev_buttons = PlayerInput.BLOCK | PlayerInput.PRIMARY
	character.coyote_ticks = 3
	character.jump_buffer_ticks = 2
	var combat: CombatState = character.combat
	combat.stamina = 137
	combat.stamina_regen_tick = 777
	combat.combat_flags = CombatState.FLAG_EXHAUSTED | CombatState.FLAG_BLOCK_HELD
	combat.parry_ready_tick = 1234
	combat.cc_until_tick = 999
	combat.buffered = CombatState.BUFFER_PRIMARY | (5 << 2)
	combat.combo_step = 2
	combat.primary_held = 9
	combat.knockback = Vector2(1.5, -2.0)
	combat.action = CombatState.Action.LIGHT
	combat.action_id = CombatCatalog.attack_id(&"sword_light_2")
	combat.action_tick = 33
	var others: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			entity.encode_spawn(40, false))
	var mine: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(entity.encode_spawn(40, true))
	if not assert_not_null(others, "se decodifica") or not assert_not_null(mine, "(propio)"):
		return
	var neutral: CombatState = CombatState.initial(CombatCatalog.rules(), combat.weapon_id)
	var seen: CombatState = others.state.combat
	assert_eq(seen.stamina, neutral.stamina, "sin la resistencia exacta del enemigo")
	assert_eq(seen.stamina_regen_tick, 0, "ni cuándo vuelve a regenerar")
	assert_eq(seen.combat_flags, 0, "ni agotado, ni botones mantenidos, ni infinita")
	assert_eq(seen.parry_ready_tick, 0, "ni cuándo no puede parar")
	assert_eq(seen.cc_until_tick, 0, "ni cuándo acaba su control")
	assert_eq(seen.buffered, 0, "ni su búfer")
	assert_eq(seen.combo_step, 0, "ni el paso del combo")
	assert_eq(seen.primary_held, 0, "ni la pulsación")
	assert_eq(seen.knockback, Vector2.ZERO, "ni el empuje")
	assert_eq(others.state.prev_buttons, 0, "ni los botones del último tick")
	assert_eq(others.state.coyote_ticks, 0, "ni los contadores de salto")
	assert_eq(others.state.jump_buffer_ticks, 0)
	# Lo que ya enseña el registro (y el animador necesita) sí: acción, arma, posición y giro.
	assert_eq(seen.action, CombatState.Action.LIGHT, "la acción en curso")
	assert_eq(seen.action_id, combat.action_id, "con su ataque")
	assert_eq(seen.action_tick, 33, "y su tick de inicio")
	assert_eq(seen.weapon_id, combat.weapon_id, "el arma equipada")
	assert_eq(others.state.position, character.get_state().position, "la posición")
	assert_eq(others.state.yaw, character.get_state().yaw, "el giro")
	# El SPAWN propio lo lleva todo.
	assert_eq(mine.state.encode(), character.get_state().encode(), "el propio, completo")
	assert_eq(mine.state.combat.stamina, 137)
	assert_eq(mine.state.combat.parry_ready_tick, 1234)
	assert_eq(mine.state.prev_buttons, PlayerInput.BLOCK | PlayerInput.PRIMARY)
	# El estado real del personaje no se toca al ocultarlo.
	assert_eq(combat.stamina, 137, "la copia enviada no altera el personaje")


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
