extends TestCase
## Pruebas de [SnapshotBuilder] (docs/red.md, sección 9.3): contenido de la cabecera, el propio
## jugador fuera de los registros, el tope de 1200 B, el acumulador de prioridad y la garantía de
## que ninguna entidad pasa más de ceil(N/C) snapshots sin enviarse (prueba de propiedades con
## 200 entidades durante 600 ticks).
## [br][br]
## Las entidades son [PlayerCharacter] sin árbol (no necesitan física para codificar su registro).

const PLAYER: int = NetProtocol.EntityKind.PLAYER
const NPC: int = NetProtocol.EntityKind.NPC
const MAX_BYTES: int = NetProtocol.MAX_PACKET_BYTES
## Registros que caben con estado propio, bloque extra y una sola sección:
## (1200 - cabecera - 2) / 21. Con el PlayerState de 111 B de la fase 4 son 50 (134 B de cabecera;
## 52 con los 69 B de la fase 3).
@warning_ignore("integer_division")
const CAPACITY: int = (NetProtocol.MAX_PACKET_BYTES - NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE
		- 2) / EntityRecord.SIZE
## sqrt(3) * 0,5 cm: error máximo de un vector cuantizado a 1 cm por eje.
const POSITION_TOLERANCE: float = 0.0087

var _nodes: Array[Node] = []


## Política de prueba con un peso por entidad (1,0 si no se indica).
class WeightedPolicy extends InterestPolicy:
	var weights: Dictionary = {}


	func priority_weight(_observer: NetEntity, entity: NetEntity) -> float:
		return weights.get(entity.net_id, 1.0)


## Entidad que cuenta cuántas veces se codifica su registro.
class CountingEntity extends NetEntity:
	var encode_calls: int = 0


	func encode_record(bytes: PackedByteArray, offset: int) -> void:
		encode_calls += 1
		super.encode_record(bytes, offset)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _randomize_character(character: PlayerCharacter, rng: RandomNumberGenerator) -> void:
	character.position = Vector3(rng.randf_range(-400.0, 400.0), rng.randf_range(-2.0, 30.0),
			rng.randf_range(-400.0, 400.0))
	character.yaw = rng.randf_range(-PI, PI)
	character.velocity = Vector3(rng.randf_range(-8.0, 8.0), rng.randf_range(-20.0, 8.0),
			rng.randf_range(-8.0, 8.0))
	character.grounded = rng.randf() < 0.7


## Jugador nuevo en el registro, con un [PlayerCharacter] sin árbol en un estado aleatorio.
func _spawn_player(registry: NetEntityRegistry, rng: RandomNumberGenerator,
		tick: int = 1) -> NetEntity:
	var entity: NetEntity = registry.allocate(PLAYER, tick)
	var character := PlayerCharacter.new()
	_nodes.append(character)
	_randomize_character(character, rng)
	entity.node = character
	entity.realm = NetProtocol.Realm.VARDHEIM
	entity.display_name = "Jugador%d" % entity.net_id
	return entity


func _spawn_players(registry: NetEntityRegistry, rng: RandomNumberGenerator,
		count: int) -> Array[NetEntity]:
	var result: Array[NetEntity] = []
	for _i: int in count:
		result.append(_spawn_player(registry, rng))
	return result


## Peer de [param entity] que ve a todos los demás de [param entities].
func _make_peer(entity: NetEntity, entities: Array[NetEntity]) -> ServerPeer:
	var peer := ServerPeer.new(entity.net_id + 1000)
	peer.state = ServerPeer.State.IN_WORLD
	peer.entity = entity
	peer.input_queue = InputQueue.new()
	peer.input_queue.reset(0, NetProtocol.neutral_input(0, 0.0))
	for other: NetEntity in entities:
		if other != entity:
			peer.relevant[other.net_id] = true
	return peer


## Ids de los registros de un snapshot decodificado.
func _record_ids(snapshot: NetMessages.Snapshot) -> Array[int]:
	var ids: Array[int] = []
	for record: EntityRecord in snapshot.records:
		ids.append(record.net_id)
	return ids


func _decode(packet: PackedByteArray) -> NetMessages.Snapshot:
	var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
	assert_not_null(snapshot, "el paquete de %d B se decodifica" % packet.size())
	return snapshot


## Mueve un poco a todos los jugadores (como lo haría la simulación de un tick).
func _step_world(entities: Array[NetEntity], rng: RandomNumberGenerator) -> void:
	for entity: NetEntity in entities:
		var character: PlayerCharacter = entity.get_character()
		character.velocity = Vector3(rng.randf_range(-8.0, 8.0), rng.randf_range(-3.0, 3.0),
				rng.randf_range(-8.0, 8.0))
		character.position += character.velocity / 60.0
		character.yaw = wrapf(character.yaw + rng.randf_range(-0.2, 0.2), -PI, PI)
		character.grounded = rng.randf() < 0.7


func _assert_record_matches(record: EntityRecord, entity: NetEntity) -> bool:
	var character: PlayerCharacter = entity.get_character()
	var ok: bool = true
	ok = assert_eq(record.net_id, entity.net_id, "net_id del registro") and ok
	# Un centímetro de resolución por eje: el error máximo es medio centímetro en cada uno.
	ok = assert_vec_near(record.position, character.position, POSITION_TOLERANCE,
			"posición de %d" % entity.net_id) and ok
	ok = assert_near(absf(angle_difference(record.yaw, character.yaw)), 0.0, TAU / 65536.0,
			"yaw de %d" % entity.net_id) and ok
	ok = assert_vec_near(record.velocity, character.velocity, POSITION_TOLERANCE,
			"velocidad de %d" % entity.net_id) and ok
	ok = assert_eq(record.is_grounded(), character.grounded,
			"grounded de %d" % entity.net_id) and ok
	ok = assert_eq(record.get_teleport_counter(), entity.teleport_counter & 3,
			"contador de teletransporte de %d" % entity.net_id) and ok
	return ok


# --- Contenido del paquete --------------------------------------------------------------------

func test_header_own_state_and_records() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 4)
	players[0].teleport_counter = 3
	players[2].teleport_counter = 1
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(77, registry.get_sorted())
	var peer: ServerPeer = _make_peer(players[0], players)
	var snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	if snapshot == null:
		return
	assert_eq(snapshot.server_tick, 77, "server_tick")
	assert_eq(snapshot.input_ack_tick, 0, "ack sin entradas: el tick del alta")
	assert_eq(snapshot.input_margin, NetProtocol.NO_MARGIN, "sin datos de antelación")
	assert_eq(snapshot.substitutions, 0, "sin sustituciones")
	assert_eq(snapshot.own_teleport, 3, "contador de teletransporte propio")
	if assert_not_null(snapshot.own_state, "trae el estado propio"):
		assert_eq(snapshot.own_state.encode(), players[0].get_character().get_state().encode(),
				"y es exactamente el estado del personaje (sin cuantizar)")
	assert_eq(_record_ids(snapshot), [2, 3, 4] as Array[int], "las demás entidades, por net_id")
	for record: EntityRecord in snapshot.records:
		assert_eq(record.kind, PLAYER, "kind del registro")
		_assert_record_matches(record, registry.get_entity(record.net_id))


func test_own_entity_never_appears_in_the_records() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 6)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(5, registry.get_sorted())
	var peer: ServerPeer = _make_peer(players[2], players)
	# Aunque por error el propio id esté entre los relevantes.
	peer.relevant[players[2].net_id] = true
	var ids: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	assert_false(ids.has(players[2].net_id), "el propio no sale en los registros")
	assert_eq(ids.size(), 5, "las otras cinco sí")


func test_header_follows_the_input_queue() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 2)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	var queue: InputQueue = peer.input_queue
	var neutral: PlayerInput = NetProtocol.neutral_input(1, 0.0)
	neutral.tick = 4
	queue.push(neutral, 0, 1)
	var second: PlayerInput = NetProtocol.neutral_input(1, 0.0)
	second.tick = 2
	queue.push(second, 0, 1)
	queue.take(1)
	queue.substitutions_total = 65536 + 7
	builder.begin(9, registry.get_sorted())
	var snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(snapshot.input_ack_tick, 2, "input_ack_tick = queue.get_ack_tick()")
	assert_eq(snapshot.input_margin, 1, "input_margin = la antelación mínima (la del tick 2)")
	assert_eq(snapshot.substitutions, 7, "substitutions & 0xFFFF")
	# build_for consume pop_min_lead(): el siguiente snapshot ya no la trae.
	builder.begin(10, registry.get_sorted())
	var next_snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(next_snapshot.input_margin, NetProtocol.NO_MARGIN, "sin datos nuevos: -128")


func test_margin_is_saturated_in_the_header() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 2)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	peer.input_queue.take(1)
	peer.input_queue.push(NetProtocol.neutral_input(1, 0.0), 0, 900)
	builder.begin(9, registry.get_sorted())
	var snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(snapshot.input_margin, -127, "una tardía enorme se satura a -127, no a «sin datos»")


func test_records_are_the_exact_bytes_of_encode_record() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 5)
	players[3].teleport_counter = 2
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(12, registry.get_sorted())
	var peer: ServerPeer = _make_peer(players[1], players)
	var packet: PackedByteArray = builder.build_for(peer)
	var header_size: int = NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE
	assert_eq(packet.size(), header_size + 2 + 4 * EntityRecord.SIZE,
			"tamaño: cabecera, sección y 4 registros")
	assert_eq(packet[header_size - 1], 1, "section_count = 1")
	assert_eq(packet[header_size], PLAYER, "kind de la sección")
	assert_eq(packet[header_size + 1], 4, "registros de la sección")
	var offset: int = header_size + 2
	for entity: NetEntity in [players[0], players[2], players[3], players[4]]:
		var expected := PackedByteArray()
		entity.encode_record(expected, 0)
		assert_eq(packet.slice(offset, offset + EntityRecord.SIZE), expected,
				"registro de %d, byte a byte" % entity.net_id)
		offset += EntityRecord.SIZE


func test_health_goes_into_the_extra_block_and_the_records() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 3)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)

	# Sin que nadie actualice la vida (todavía no hay Combatant): sana, con el bloque extra.
	builder.begin(10, registry.get_sorted())
	var plain: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(plain.health, NetEntity.DEFAULT_HEALTH, "vida por defecto en el bloque extra")
	assert_eq(plain.max_health, NetEntity.DEFAULT_HEALTH, "vida máxima por defecto")
	assert_eq(plain.status, 0, "sin estado")
	assert_eq(plain.respawn_tick, 0, "sin reaparición")
	for record: EntityRecord in plain.records:
		assert_eq(record.health_q, EntityRecord.HEALTH_Q_FULL, "los demás, con la vida llena (255)")

	# Con la vida actualizada: el bloque extra es la del observador y cada registro la suya.
	players[0].set_health_view(700, 1000,
			NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_PROTECTED, 0)
	players[1].set_health_view(500, 1000, 0, 0)
	players[2].set_health_view(0, 1000, NetMessages.STATUS_DEAD, 9999)
	builder.begin(11, registry.get_sorted())
	var snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(snapshot.health, 700, "vida propia")
	assert_eq(snapshot.max_health, 1000, "vida máxima propia")
	assert_true(snapshot.is_in_combat(), "propio en combate")
	assert_true(snapshot.is_protected(), "propio protegido")
	assert_false(snapshot.is_dead(), "propio vivo")
	assert_eq(snapshot.respawn_tick, 0, "propio vivo: sin tick de reaparición")
	assert_eq(snapshot.records.size(), 2, "los otros dos jugadores")
	assert_eq(snapshot.records[0].net_id, players[1].net_id, "primer registro")
	assert_eq(snapshot.records[0].health_q, EntityRecord.quantize_health(500, 1000),
			"vida cuantizada del jugador a la mitad")
	assert_eq(snapshot.records[1].health_q, 0, "el muerto lleva health_q 0")

	# El propio muerto: el bloque lleva el tick de reaparición.
	var dead_peer: ServerPeer = _make_peer(players[2], players)
	var dead_snapshot: NetMessages.Snapshot = _decode(builder.build_for(dead_peer))
	assert_true(dead_snapshot.is_dead(), "propio muerto")
	assert_eq(dead_snapshot.health, 0, "sin vida")
	assert_eq(dead_snapshot.respawn_tick, 9999, "tick de reaparición")


func test_protocol_6_bits_3_of_the_records_and_of_the_extra_block() -> void:
	# docs/habilidades.md, sección 5.2: bit 3 de los flags del registro = ranura de arma 2 activa; bit 3 del
	# status del bloque extra = derribado (su vida y su máximo son los de derribado).
	var rng := RandomNumberGenerator.new()
	rng.seed = 66
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 3)
	var swapped: PlayerCharacter = players[1].get_character()
	swapped.combat.alt_weapon_id = CombatCatalog.weapon_id(&"bow")
	swapped.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	players[0].set_health_view(250, 400, NetMessages.STATUS_DOWNED | NetMessages.STATUS_IN_COMBAT, 0)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	builder.begin(20, registry.get_sorted())
	var packet: PackedByteArray = builder.build_for(peer)
	assert_true(packet.size() <= MAX_BYTES, "como mucho 1200 B")
	var snapshot: NetMessages.Snapshot = _decode(packet)
	if snapshot == null:
		return
	assert_true(snapshot.is_downed(), "el propio derribado: bit 3 del status")
	assert_false(snapshot.is_dead(), "y no muerto")
	assert_eq(snapshot.health, 250, "vida de derribado")
	assert_eq(snapshot.max_health, 400, "máximo de derribado")
	assert_eq(snapshot.records.size(), 2, "los otros dos")
	for record: EntityRecord in snapshot.records:
		var entity: NetEntity = registry.get_entity(record.net_id)
		_assert_record_matches(record, entity)
		assert_eq(record.is_second_slot(), entity == players[1],
				"bit 3 del registro de %d: la ranura 2 activa" % record.net_id)


func test_relevant_flag_false_and_unknown_ids_are_not_sent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 5)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(3, registry.get_sorted())
	var peer: ServerPeer = _make_peer(players[0], players)
	peer.relevant[players[1].net_id] = false
	peer.relevant[4000] = true
	peer.priority[4000] = 9.0
	peer.priority[players[1].net_id] = 9.0
	var ids: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	assert_eq(ids, [3, 4, 5] as Array[int],
			"ni los marcados como no relevantes ni los desconocidos")
	assert_false(peer.priority.has(4000), "la prioridad de lo desconocido se descarta")
	assert_false(peer.priority.has(players[1].net_id), "y la de lo que ya no es relevante")


func test_removed_entities_disappear_from_later_snapshots() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 4)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	builder.begin(1, registry.get_sorted())
	assert_eq(_record_ids(_decode(builder.build_for(peer))), [2, 3, 4] as Array[int],
			"al principio")
	registry.release(3, 2)
	builder.begin(2, registry.get_sorted())
	# El peer aún tiene al 3 por relevante (el servidor lo actualiza cada 6 ticks): no sale.
	assert_eq(_record_ids(_decode(builder.build_for(peer))), [2, 4] as Array[int], "sin el 3")
	assert_false(peer.priority.has(3), "y su prioridad se descarta")


func test_peer_without_character_gets_no_own_state_and_more_room() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 80)
	# Observador sin PlayerCharacter (un nodo cualquiera).
	var observer: NetEntity = registry.allocate(NetProtocol.EntityKind.NPC, 1)
	var plain := Node3D.new()
	_nodes.append(plain)
	observer.node = plain
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(4, registry.get_sorted())
	var peer: ServerPeer = _make_peer(observer, players)
	var packet: PackedByteArray = builder.build_for(peer)
	var snapshot: NetMessages.Snapshot = _decode(packet)
	assert_null(snapshot.own_state, "sin personaje no hay estado propio")
	var no_state_capacity: int = floori((MAX_BYTES - NetMessages.SNAPSHOT_HEADER_SIZE - 2)
			/ float(EntityRecord.SIZE))
	assert_eq(snapshot.records.size(), no_state_capacity,
			"sin estado propio caben (1200 - 14 - 2) / 21 = %d registros" % no_state_capacity)
	assert_eq(no_state_capacity, 56, "56 registros sin estado propio")
	assert_true(packet.size() <= MAX_BYTES, "y el paquete sigue sin pasar de 1200 B")


func test_npc_and_player_sections() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 3)
	var npcs: Array[NetEntity] = []
	for _i: int in 3:
		var npc: NetEntity = registry.allocate(NPC, 1)
		var body := Node3D.new()
		_nodes.append(body)
		body.position = Vector3(10, 0, 20)
		npc.node = body
		npcs.append(npc)
	var everyone: Array[NetEntity] = []
	everyone.append_array(players)
	everyone.append_array(npcs)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(6, registry.get_sorted())
	var peer: ServerPeer = _make_peer(players[0], everyone)
	var snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	var kinds: Array[int] = []
	for record: EntityRecord in snapshot.records:
		kinds.append(record.kind)
	assert_eq(kinds, [PLAYER, PLAYER, NPC, NPC, NPC] as Array[int],
			"una sección de jugadores y otra de PNJ")
	assert_eq(_record_ids(snapshot), [2, 3, 4, 5, 6] as Array[int],
			"por net_id dentro de cada sección")
	assert_vec_near(snapshot.records[2].position, Vector3(10, 0, 20), POSITION_TOLERANCE,
			"posición del PNJ")
	assert_true(snapshot.records[2].is_grounded(), "un PNJ simple va en el suelo")


func test_structures_are_not_stream_records() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 10
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 2)
	var structure: NetEntity = registry.allocate(NetProtocol.EntityKind.STRUCTURE, 1)
	var body := Node3D.new()
	_nodes.append(body)
	structure.node = body
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(2, registry.get_sorted())
	var everyone: Array[NetEntity] = [players[0], players[1], structure]
	var peer: ServerPeer = _make_peer(players[0], everyone)
	assert_eq(_record_ids(_decode(builder.build_for(peer))), [2] as Array[int],
			"las estructuras se replican por OBJECT_STATE, no por snapshot")


func test_empty_world() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 1)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(1, registry.get_sorted())
	var packet: PackedByteArray = builder.build_for(_make_peer(players[0], players))
	assert_eq(packet.size(), NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE, "solo la cabecera")
	var snapshot: NetMessages.Snapshot = _decode(packet)
	assert_eq(snapshot.records.size(), 0, "sin registros")
	var lonely_builder := SnapshotBuilder.new(null)
	assert_eq(lonely_builder.build_for(_make_peer(players[0], players)).size(),
			NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE,
			"sin begin() tampoco falla (y sin política)")


# --- Tope de 1200 B y presupuesto -------------------------------------------------------------

func test_packet_never_exceeds_the_limit_for_any_player_count() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 71)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(1, registry.get_sorted())
	for others: int in range(0, 71):
		var visible: Array[NetEntity] = [players[0]]
		visible.append_array(players.slice(1, 1 + others))
		var peer: ServerPeer = _make_peer(players[0], visible)
		var packet: PackedByteArray = builder.build_for(peer)
		var written: int = mini(others, CAPACITY)
		var expected_size: int = NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE \
				+ (2 + written * EntityRecord.SIZE if written > 0 else 0)
		if packet.size() != expected_size or packet.size() > MAX_BYTES:
			fail("con %d visibles: %d B (se esperaban %d y como mucho %d)"
					% [others, packet.size(), expected_size, MAX_BYTES])
			return
		var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
		if snapshot == null or snapshot.records.size() != written:
			fail("con %d visibles el paquete no se decodifica con %d registros" % [others, written])
			return
	var full_size: int = NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE + 2 \
			+ CAPACITY * EntityRecord.SIZE
	assert_true(full_size <= MAX_BYTES, "los %d registros llenos caben" % CAPACITY)
	assert_true(full_size + EntityRecord.SIZE > MAX_BYTES, "uno más ya no cabría")
	# Con el PlayerState de 111 B de la fase 4: 50 registros en 1186 B (habilidades.md, sección 3.1).
	if PlayerState.ENCODED_SIZE == 111:
		assert_eq(CAPACITY, 50, "capacidad del documento: 50 registros")
		assert_eq(full_size, 1186, "50 registros ocupan 1186 B")


func test_with_63_visible_players_every_entity_goes_out_at_least_every_other_snapshot() -> void:
	# La garantía de red.md 9.3: 63 jugadores visibles y CAPACITY plazas (50 con el estado de
	# 111 B), cada entidad sale al menos uno de cada dos snapshots: ceil(63 / C) = 2.
	assert_eq(ceili(63.0 / float(CAPACITY)), 2, "con 63 candidatas ceil(N / C) es 2")
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 64)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	var previous_sent: Dictionary = {}
	for snapshot_index: int in 200:
		builder.begin(snapshot_index + 1, registry.get_sorted())
		var ids: Array[int] = _record_ids(_decode(builder.build_for(peer)))
		assert_eq(ids.size(), CAPACITY, "%d registros por paquete" % CAPACITY)
		for net_id: int in range(2, 65):
			var sent: bool = ids.has(net_id)
			if not sent and previous_sent.get(net_id, true) == false:
				fail("la entidad %d no salió en dos snapshots seguidos (%d)"
						% [net_id, snapshot_index])
				return
			previous_sent[net_id] = sent


func test_priority_accumulator_orders_the_unsent_first() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 14
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 101)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	# 100 candidatas (ids 2..101) y CAPACITY plazas. Con todas a prioridad 1 gana el menor net_id.
	var first_unsent: int = 2 + CAPACITY
	var waiting: int = 100 - CAPACITY
	builder.begin(1, registry.get_sorted())
	var first: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	assert_eq(first, range(2, first_unsent),
			"primer snapshot: las %d de menor net_id (desempate por id)" % CAPACITY)
	assert_near(peer.priority[2], 0.0, 1e-9, "las escritas vuelven a 0")
	assert_near(peer.priority[first_unsent], 1.0, 1e-9, "las demás acumulan el peso")
	# Segundo: las que no salieron (prioridad 2) y las primeras de las que ya salieron hasta llenar.
	builder.begin(2, registry.get_sorted())
	var second: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	var expected_second: Array[int] = []
	expected_second.append_array(range(2, 2 + CAPACITY - waiting))
	expected_second.append_array(range(first_unsent, 102))
	assert_eq(second, expected_second,
			"segundo snapshot: todas las que esperaban y %d más" % (CAPACITY - waiting))
	assert_near(peer.priority[first_unsent], 0.0, 1e-9, "las que salieron, a 0")
	assert_near(peer.priority[first_unsent - 1], 1.0, 1e-9,
			"las que salieron antes y ahora no, empiezan de nuevo")
	if CAPACITY > waiting:
		assert_near(peer.priority[2], 0.0, 1e-9, "las que sí salieron de nuevo, a 0")
	else:
		# Con 50 plazas y 50 esperando, el segundo solo lleva las que esperaban.
		assert_near(peer.priority[2], 1.0, 1e-9, "las que no caben esta vez acumulan el peso")


func test_priority_weights_decide_what_goes_first() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 15
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 101)
	var policy := WeightedPolicy.new()
	for net_id: int in range(2, 102):
		policy.weights[net_id] = float(net_id)
	var builder := SnapshotBuilder.new(policy)
	var peer: ServerPeer = _make_peer(players[0], players)
	builder.begin(1, registry.get_sorted())
	var first: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	assert_eq(first, range(102 - CAPACITY, 102),
			"con pesos iguales al id salen los %d de mayor peso" % CAPACITY)
	assert_near(peer.priority[10], 10.0, 1e-9, "una no enviada acumula su peso")
	assert_near(peer.priority[100], 0.0, 1e-9, "una enviada vuelve a 0")


func test_priority_matches_a_reference_model_over_many_snapshots() -> void:
	# Modelo de referencia independiente: acumular, ordenar por (prioridad desc, id asc) con
	# sort_custom, tomar las C primeras y poner a 0 las enviadas.
	var rng := RandomNumberGenerator.new()
	rng.seed = 16
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 151)
	var policy := WeightedPolicy.new()
	var builder := SnapshotBuilder.new(policy)
	var peer: ServerPeer = _make_peer(players[0], players)
	var model: Dictionary = {}
	var weight_choices: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0, 0.0]
	for snapshot_index: int in 150:
		for net_id: int in range(2, 152):
			policy.weights[net_id] = weight_choices[rng.randi() % weight_choices.size()]
		builder.begin(snapshot_index + 1, registry.get_sorted())
		var ids: Array[int] = _record_ids(_decode(builder.build_for(peer)))

		var candidates: Array[int] = []
		for net_id: int in range(2, 152):
			model[net_id] = model.get(net_id, 0.0) + policy.weights[net_id]
			candidates.append(net_id)
		candidates.sort_custom(func(a: int, b: int) -> bool:
			if model[a] != model[b]:
				return model[a] > model[b]
			return a < b)
		var expected: Array[int] = candidates.slice(0, CAPACITY)
		for net_id: int in expected:
			model[net_id] = 0.0
		expected.sort()
		if ids != expected:
			fail("el snapshot %d no coincide con el modelo de referencia" % snapshot_index)
			return


func test_extreme_weights_do_not_break_the_packet() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 80)
	var policy := WeightedPolicy.new()
	policy.weights[2] = INF
	policy.weights[3] = NAN
	policy.weights[4] = -5.0
	policy.weights[5] = 1e30
	var builder := SnapshotBuilder.new(policy)
	var peer: ServerPeer = _make_peer(players[0], players)
	for tick: int in range(1, 6):
		builder.begin(tick, registry.get_sorted())
		var packet: PackedByteArray = builder.build_for(peer)
		assert_true(packet.size() <= MAX_BYTES, "tick %d: como mucho 1200 B" % tick)
		var snapshot: NetMessages.Snapshot = _decode(packet)
		assert_eq(snapshot.records.size(), CAPACITY, "%d registros" % CAPACITY)
		assert_true(_record_ids(snapshot).has(2) and _record_ids(snapshot).has(5),
				"los pesos enormes siempre salen")
	for net_id: int in peer.priority:
		assert_false(is_nan(peer.priority[net_id]), "la prioridad de %d no es NaN" % net_id)
		assert_true(peer.priority[net_id] >= 0.0, "ni negativa (%d)" % net_id)


func test_each_record_is_encoded_once_per_tick_for_all_peers() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 18
	var registry := NetEntityRegistry.new()
	var counted: Array[CountingEntity] = []
	var all: Array[NetEntity] = []
	for _i: int in 30:
		var entity := CountingEntity.new()
		entity.net_id = counted.size() + 1
		entity.kind = PLAYER
		var character := PlayerCharacter.new()
		_nodes.append(character)
		_randomize_character(character, rng)
		entity.node = character
		counted.append(entity)
		all.append(entity)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(1, all)
	var packets: Array[PackedByteArray] = []
	for entity: NetEntity in all:
		packets.append(builder.build_for(_make_peer(entity, all)))
	assert_eq(packets.size(), 30, "un paquete por peer")
	for entity: CountingEntity in counted:
		assert_eq(entity.encode_calls, 1, "la entidad %d se codificó una sola vez" % entity.net_id)
	builder.begin(2, all)
	for entity: CountingEntity in counted:
		assert_eq(entity.encode_calls, 2, "y una vez más en el tick siguiente")


func test_same_inputs_give_the_same_bytes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 19
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 90)
	var builder_a := SnapshotBuilder.new(InterestPolicy.new())
	var builder_b := SnapshotBuilder.new(InterestPolicy.new())
	var peer_a: ServerPeer = _make_peer(players[0], players)
	var peer_b: ServerPeer = _make_peer(players[0], players)
	for tick: int in range(1, 21):
		builder_a.begin(tick, registry.get_sorted())
		builder_b.begin(tick, registry.get_sorted())
		assert_eq(builder_a.build_for(peer_a), builder_b.build_for(peer_b), "tick %d" % tick)
		_step_world(players, rng)


# --- Prueba de propiedades: 200 entidades, 600 ticks ------------------------------------------

## Un observador de la prueba de propiedades.
class Observer:
	var peer: ServerPeer
	## Máximo de snapshots seguidos que una entidad relevante lleva sin enviarse.
	var max_wait: int = 0
	## Máximo de candidatas (relevantes y existentes) que ha tenido a la vez.
	var max_candidates: int = 0
	var waiting: Dictionary = {}
	var snapshots: int = 0


func test_property_200_entities_600_ticks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260601
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 200)
	var builder := SnapshotBuilder.new(InterestPolicy.new())

	# A ve a todos; B ve un subconjunto que cambia cada 25 ticks; C ve a 30 más las 15 que entran
	# (caben todas: CAPACITY es 50 con el estado de 111 B).
	var observer_a := Observer.new()
	observer_a.peer = _make_peer(players[0], players)
	var nobody: Array[NetEntity] = []
	var observer_b := Observer.new()
	observer_b.peer = _make_peer(players[1], nobody)
	var observer_c := Observer.new()
	observer_c.peer = _make_peer(players[2], nobody)
	for i: int in range(3, 33):
		observer_c.peer.relevant[players[i].net_id] = true
	var observers: Array[Observer] = [observer_a, observer_b, observer_c]

	var oversize: int = 0
	var undecodable: int = 0
	var own_leaks: int = 0
	var duplicates: int = 0
	var record_mismatches: int = 0
	for tick: int in range(1, 601):
		_step_world(registry.get_sorted(), rng)
		if tick % 25 == 1:
			observer_b.peer.relevant.clear()
			for entity: NetEntity in players:
				if entity.net_id != players[1].net_id and rng.randf() < 0.6:
					observer_b.peer.relevant[entity.net_id] = true
		# Algunas entidades salen y entran: sus ids se quedan como relevantes un rato.
		if tick % 40 == 0:
			var leaver: NetEntity = players[rng.randi_range(10, players.size() - 1)]
			registry.release(leaver.net_id, tick)
			players.erase(leaver)
			var newcomer: NetEntity = _spawn_player(registry, rng, tick)
			players.append(newcomer)
			for observer: Observer in observers:
				observer.peer.relevant[newcomer.net_id] = true
		builder.begin(tick, registry.get_sorted())
		for observer: Observer in observers:
			var packet: PackedByteArray = builder.build_for(observer.peer)
			if packet.size() > MAX_BYTES:
				oversize += 1
			var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
			if snapshot == null:
				undecodable += 1
				continue
			var own_id: int = observer.peer.entity.net_id
			var sent: Dictionary = {}
			for record: EntityRecord in snapshot.records:
				if record.net_id == own_id:
					own_leaks += 1
				if sent.has(record.net_id):
					duplicates += 1
				sent[record.net_id] = true
				var entity: NetEntity = registry.get_entity(record.net_id)
				if entity == null \
						or record.position.distance_to(entity.get_position()) > POSITION_TOLERANCE:
					record_mismatches += 1
			# Espera de cada candidata: snapshots seguidos como relevante sin que saliera.
			var candidates: Dictionary = {}
			for net_id: int in observer.peer.relevant:
				if net_id != own_id and registry.get_entity(net_id) != null:
					candidates[net_id] = true
			observer.max_candidates = maxi(observer.max_candidates, candidates.size())
			for net_id: int in observer.waiting.keys():
				if not candidates.has(net_id):
					observer.waiting.erase(net_id)
			for net_id: int in candidates:
				if sent.has(net_id):
					observer.waiting[net_id] = 0
				else:
					observer.waiting[net_id] = observer.waiting.get(net_id, 0) + 1
					observer.max_wait = maxi(observer.max_wait, observer.waiting[net_id])
			observer.snapshots += 1
	assert_eq(oversize, 0, "ningún paquete pasa de 1200 B")
	assert_eq(undecodable, 0, "todos se decodifican con NetMessages.Snapshot.decode")
	assert_eq(own_leaks, 0, "el propio jugador nunca aparece entre los registros")
	assert_eq(duplicates, 0, "ningún registro repetido en un paquete")
	assert_eq(record_mismatches, 0, "cada registro coincide con la posición de su entidad")
	for observer: Observer in observers:
		var bound: int = ceili(observer.max_candidates / float(CAPACITY))
		assert_eq(observer.snapshots, 600, "600 snapshots")
		assert_true(observer.max_wait <= bound,
				("ninguna entidad pasa más de ceil(N/C) = %d snapshots sin enviarse "
				+ "(N = %d, C = %d): máximo observado %d")
				% [bound, observer.max_candidates, CAPACITY, observer.max_wait])
	assert_true(observer_a.max_candidates >= 199, "el observador A llegó a ver a 199")
	assert_true(observer_a.max_wait >= 1,
			"con 199 candidatas y %d plazas alguna tuvo que esperar" % CAPACITY)
	assert_true(observer_c.max_candidates <= CAPACITY,
			"C nunca tiene más candidatas que plazas (%d de %d)" % [observer_c.max_candidates, CAPACITY])
	assert_eq(observer_c.max_wait, 0, "con todas sus candidatas cabiendo, ninguna espera")
