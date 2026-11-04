extends TestCase
## Tests for [SnapshotBuilder] (docs/networking.md, section 9.3): header contents, the player
## themselves left out of the records, the 1200 B cap, the priority accumulator and the guarantee
## that no entity goes more than ceil(N/C) snapshots without being sent (property test with
## 200 entities over 600 ticks).
## [br][br]
## The entities are [PlayerCharacter]s without a tree (they do not need physics to encode their record).

const PLAYER: int = NetProtocol.EntityKind.PLAYER
const NPC: int = NetProtocol.EntityKind.NPC
const MAX_BYTES: int = NetProtocol.MAX_PACKET_BYTES
## Records that fit with own state, extra block and a single section:
## (1200 - header - 2) / 21. With the 111 B PlayerState of phase 4 that is 50 (134 B of header;
## 52 with the 69 B of phase 3).
@warning_ignore("integer_division")
const CAPACITY: int = (NetProtocol.MAX_PACKET_BYTES - NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE
		- 2) / EntityRecord.SIZE
## sqrt(3) * 0.5 cm: maximum error of a vector quantized to 1 cm per axis.
const POSITION_TOLERANCE: float = 0.0087

var _nodes: Array[Node] = []


## Test policy with one weight per entity (1.0 if not specified).
class WeightedPolicy extends InterestPolicy:
	var weights: Dictionary = {}


	func priority_weight(_observer: NetEntity, entity: NetEntity) -> float:
		return weights.get(entity.net_id, 1.0)


## Entity that counts how many times its record is encoded.
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


# --- Helpers ----------------------------------------------------------------------------------

func _randomize_character(character: PlayerCharacter, rng: RandomNumberGenerator) -> void:
	character.position = Vector3(rng.randf_range(-400.0, 400.0), rng.randf_range(-2.0, 30.0),
			rng.randf_range(-400.0, 400.0))
	character.yaw = rng.randf_range(-PI, PI)
	character.velocity = Vector3(rng.randf_range(-8.0, 8.0), rng.randf_range(-20.0, 8.0),
			rng.randf_range(-8.0, 8.0))
	character.grounded = rng.randf() < 0.7


## New player in the registry, with a tree-less [PlayerCharacter] in a random state.
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


## Peer of [param entity] who sees all the others in [param entities].
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


## Ids of the records of a decoded snapshot.
func _record_ids(snapshot: NetMessages.Snapshot) -> Array[int]:
	var ids: Array[int] = []
	for record: EntityRecord in snapshot.records:
		ids.append(record.net_id)
	return ids


func _decode(packet: PackedByteArray) -> NetMessages.Snapshot:
	var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
	assert_not_null(snapshot, "the %d B packet decodes" % packet.size())
	return snapshot


## Moves all the players a little (as a tick's simulation would).
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
	ok = assert_eq(record.net_id, entity.net_id, "record's net_id") and ok
	# One centimeter of resolution per axis: the maximum error is half a centimeter on each.
	ok = assert_vec_near(record.position, character.position, POSITION_TOLERANCE,
			"position of %d" % entity.net_id) and ok
	ok = assert_near(absf(angle_difference(record.yaw, character.yaw)), 0.0, TAU / 65536.0,
			"yaw of %d" % entity.net_id) and ok
	ok = assert_vec_near(record.velocity, character.velocity, POSITION_TOLERANCE,
			"velocity of %d" % entity.net_id) and ok
	ok = assert_eq(record.is_grounded(), character.grounded,
			"grounded of %d" % entity.net_id) and ok
	ok = assert_eq(record.get_teleport_counter(), entity.teleport_counter & 3,
			"teleport counter of %d" % entity.net_id) and ok
	return ok


# --- Packet contents --------------------------------------------------------------------------

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
	assert_eq(snapshot.input_ack_tick, 0, "ack with no inputs: the join tick")
	assert_eq(snapshot.input_margin, NetProtocol.NO_MARGIN, "no lead data")
	assert_eq(snapshot.substitutions, 0, "no substitutions")
	assert_eq(snapshot.own_teleport, 3, "own teleport counter")
	if assert_not_null(snapshot.own_state, "carries the own state"):
		assert_eq(snapshot.own_state.encode(), players[0].get_character().get_state().encode(),
				"and it is exactly the character's state (unquantized)")
	assert_eq(_record_ids(snapshot), [2, 3, 4] as Array[int], "the other entities, by net_id")
	for record: EntityRecord in snapshot.records:
		assert_eq(record.kind, PLAYER, "record's kind")
		_assert_record_matches(record, registry.get_entity(record.net_id))


func test_own_entity_never_appears_in_the_records() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 6)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(5, registry.get_sorted())
	var peer: ServerPeer = _make_peer(players[2], players)
	# Even if by mistake the own id is among the relevant ones.
	peer.relevant[players[2].net_id] = true
	var ids: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	assert_false(ids.has(players[2].net_id), "the own one does not appear in the records")
	assert_eq(ids.size(), 5, "the other five do")


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
	assert_eq(snapshot.input_margin, 1, "input_margin = the minimum lead (that of tick 2)")
	assert_eq(snapshot.substitutions, 7, "substitutions & 0xFFFF")
	# build_for consumes pop_min_lead(): the next snapshot no longer carries it.
	builder.begin(10, registry.get_sorted())
	var next_snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(next_snapshot.input_margin, NetProtocol.NO_MARGIN, "without new data: -128")


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
	assert_eq(snapshot.input_margin, -127, "a hugely late one saturates at -127, not at \"no data\"")


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
			"size: header, section and 4 records")
	assert_eq(packet[header_size - 1], 1, "section_count = 1")
	assert_eq(packet[header_size], PLAYER, "section's kind")
	assert_eq(packet[header_size + 1], 4, "section's records")
	var offset: int = header_size + 2
	for entity: NetEntity in [players[0], players[2], players[3], players[4]]:
		var expected := PackedByteArray()
		entity.encode_record(expected, 0)
		assert_eq(packet.slice(offset, offset + EntityRecord.SIZE), expected,
				"record of %d, byte by byte" % entity.net_id)
		offset += EntityRecord.SIZE


func test_health_goes_into_the_extra_block_and_the_records() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 3)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)

	# Without anyone updating the health (there is no Combatant yet): healthy, with the extra block.
	builder.begin(10, registry.get_sorted())
	var plain: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(plain.health, NetEntity.DEFAULT_HEALTH, "default health in the extra block")
	assert_eq(plain.max_health, NetEntity.DEFAULT_HEALTH, "default maximum health")
	assert_eq(plain.status, 0, "no status")
	assert_eq(plain.respawn_tick, 0, "no respawn")
	for record: EntityRecord in plain.records:
		assert_eq(record.health_q, EntityRecord.HEALTH_Q_FULL, "the others, with full health (255)")

	# With health updated: the extra block carries the observer's and each record its own.
	players[0].set_health_view(700, 1000,
			NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_PROTECTED, 0)
	players[1].set_health_view(500, 1000, 0, 0)
	players[2].set_health_view(0, 1000, NetMessages.STATUS_DEAD, 9999)
	builder.begin(11, registry.get_sorted())
	var snapshot: NetMessages.Snapshot = _decode(builder.build_for(peer))
	assert_eq(snapshot.health, 700, "own health")
	assert_eq(snapshot.max_health, 1000, "own maximum health")
	assert_true(snapshot.is_in_combat(), "own in combat")
	assert_true(snapshot.is_protected(), "own protected")
	assert_false(snapshot.is_dead(), "own alive")
	assert_eq(snapshot.respawn_tick, 0, "own alive: no respawn tick")
	assert_eq(snapshot.records.size(), 2, "the other two players")
	assert_eq(snapshot.records[0].net_id, players[1].net_id, "first record")
	assert_eq(snapshot.records[0].health_q, EntityRecord.quantize_health(500, 1000),
			"quantized health of the player at half")
	assert_eq(snapshot.records[1].health_q, 0, "the dead one carries health_q 0")

	# The own dead: the block carries the respawn tick.
	var dead_peer: ServerPeer = _make_peer(players[2], players)
	var dead_snapshot: NetMessages.Snapshot = _decode(builder.build_for(dead_peer))
	assert_true(dead_snapshot.is_dead(), "own dead")
	assert_eq(dead_snapshot.health, 0, "no health")
	assert_eq(dead_snapshot.respawn_tick, 9999, "respawn tick")


func test_protocol_6_bits_3_of_the_records_and_of_the_extra_block() -> void:
	# docs/abilities.md, section 5.2: bit 3 of the record's flags = weapon slot 2 active; bit 3 of the
	# extra block's status = knocked down (its health and its maximum are those of knocked down).
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
	assert_true(packet.size() <= MAX_BYTES, "at most 1200 B")
	var snapshot: NetMessages.Snapshot = _decode(packet)
	if snapshot == null:
		return
	assert_true(snapshot.is_downed(), "the own knocked down: bit 3 of the status")
	assert_false(snapshot.is_dead(), "and not dead")
	assert_eq(snapshot.health, 250, "knocked-down health")
	assert_eq(snapshot.max_health, 400, "knocked-down maximum")
	assert_eq(snapshot.records.size(), 2, "the other two")
	for record: EntityRecord in snapshot.records:
		var entity: NetEntity = registry.get_entity(record.net_id)
		_assert_record_matches(record, entity)
		assert_eq(record.is_second_slot(), entity == players[1],
				"bit 3 of the record of %d: slot 2 active" % record.net_id)


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
			"neither those marked as not relevant nor the unknown ones")
	assert_false(peer.priority.has(4000), "the priority of the unknown is discarded")
	assert_false(peer.priority.has(players[1].net_id), "and that of what is no longer relevant")


func test_removed_entities_disappear_from_later_snapshots() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 4)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	var peer: ServerPeer = _make_peer(players[0], players)
	builder.begin(1, registry.get_sorted())
	assert_eq(_record_ids(_decode(builder.build_for(peer))), [2, 3, 4] as Array[int],
			"at the start")
	registry.release(3, 2)
	builder.begin(2, registry.get_sorted())
	# The peer still has 3 as relevant (the server updates it every 6 ticks): it does not go out.
	assert_eq(_record_ids(_decode(builder.build_for(peer))), [2, 4] as Array[int], "without 3")
	assert_false(peer.priority.has(3), "and its priority is discarded")


func test_peer_without_character_gets_no_own_state_and_more_room() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 80)
	# Observer without a PlayerCharacter (any node).
	var observer: NetEntity = registry.allocate(NetProtocol.EntityKind.NPC, 1)
	var plain := Node3D.new()
	_nodes.append(plain)
	observer.node = plain
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(4, registry.get_sorted())
	var peer: ServerPeer = _make_peer(observer, players)
	var packet: PackedByteArray = builder.build_for(peer)
	var snapshot: NetMessages.Snapshot = _decode(packet)
	assert_null(snapshot.own_state, "without a character there is no own state")
	var no_state_capacity: int = floori((MAX_BYTES - NetMessages.SNAPSHOT_HEADER_SIZE - 2)
			/ float(EntityRecord.SIZE))
	assert_eq(snapshot.records.size(), no_state_capacity,
			"without own state, (1200 - 14 - 2) / 21 = %d records fit" % no_state_capacity)
	assert_eq(no_state_capacity, 56, "56 records without own state")
	assert_true(packet.size() <= MAX_BYTES, "and the packet still does not exceed 1200 B")


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
			"one player section and one NPC section")
	assert_eq(_record_ids(snapshot), [2, 3, 4, 5, 6] as Array[int],
			"by net_id within each section")
	assert_vec_near(snapshot.records[2].position, Vector3(10, 0, 20), POSITION_TOLERANCE,
			"NPC position")
	assert_true(snapshot.records[2].is_grounded(), "a simple NPC goes on the ground")


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
			"structures are replicated through OBJECT_STATE, not through snapshots")


func test_empty_world() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 1)
	var builder := SnapshotBuilder.new(InterestPolicy.new())
	builder.begin(1, registry.get_sorted())
	var packet: PackedByteArray = builder.build_for(_make_peer(players[0], players))
	assert_eq(packet.size(), NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE, "only the header")
	var snapshot: NetMessages.Snapshot = _decode(packet)
	assert_eq(snapshot.records.size(), 0, "no records")
	var lonely_builder := SnapshotBuilder.new(null)
	assert_eq(lonely_builder.build_for(_make_peer(players[0], players)).size(),
			NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE,
			"without begin() it does not fail either (and without a policy)")


# --- 1200 B cap and budget --------------------------------------------------------------------

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
			fail("with %d visible: %d B (%d expected and at most %d)"
					% [others, packet.size(), expected_size, MAX_BYTES])
			return
		var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
		if snapshot == null or snapshot.records.size() != written:
			fail("with %d visible the packet does not decode with %d records" % [others, written])
			return
	var full_size: int = NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE + 2 \
			+ CAPACITY * EntityRecord.SIZE
	assert_true(full_size <= MAX_BYTES, "the %d full records fit" % CAPACITY)
	assert_true(full_size + EntityRecord.SIZE > MAX_BYTES, "one more would no longer fit")
	# With the 111 B PlayerState of phase 4: 50 records in 1186 B (abilities.md, section 3.1).
	if PlayerState.ENCODED_SIZE == 111:
		assert_eq(CAPACITY, 50, "the document's capacity: 50 records")
		assert_eq(full_size, 1186, "50 records take up 1186 B")


func test_with_63_visible_players_every_entity_goes_out_at_least_every_other_snapshot() -> void:
	# The guarantee of networking.md 9.3: 63 visible players and CAPACITY slots (50 with the
	# 111 B state), each entity goes out at least one in every two snapshots: ceil(63 / C) = 2.
	assert_eq(ceili(63.0 / float(CAPACITY)), 2, "with 63 candidates ceil(N / C) is 2")
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
		assert_eq(ids.size(), CAPACITY, "%d records per packet" % CAPACITY)
		for net_id: int in range(2, 65):
			var sent: bool = ids.has(net_id)
			if not sent and previous_sent.get(net_id, true) == false:
				fail("entity %d did not go out in two consecutive snapshots (%d)"
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
	# 100 candidates (ids 2..101) and CAPACITY slots. With all at priority 1 the lowest net_id wins.
	var first_unsent: int = 2 + CAPACITY
	var waiting: int = 100 - CAPACITY
	builder.begin(1, registry.get_sorted())
	var first: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	assert_eq(first, range(2, first_unsent),
			"first snapshot: the %d with the lowest net_id (tie broken by id)" % CAPACITY)
	assert_near(peer.priority[2], 0.0, 1e-9, "those written go back to 0")
	assert_near(peer.priority[first_unsent], 1.0, 1e-9, "the rest accumulate the weight")
	# Second: those that did not go out (priority 2) and the first of those that did, until full.
	builder.begin(2, registry.get_sorted())
	var second: Array[int] = _record_ids(_decode(builder.build_for(peer)))
	var expected_second: Array[int] = []
	expected_second.append_array(range(2, 2 + CAPACITY - waiting))
	expected_second.append_array(range(first_unsent, 102))
	assert_eq(second, expected_second,
			"second snapshot: all those that were waiting and %d more" % (CAPACITY - waiting))
	assert_near(peer.priority[first_unsent], 0.0, 1e-9, "those that went out, at 0")
	assert_near(peer.priority[first_unsent - 1], 1.0, 1e-9,
			"those that went out before and now do not, start over")
	if CAPACITY > waiting:
		assert_near(peer.priority[2], 0.0, 1e-9, "those that did go out again, at 0")
	else:
		# With 50 slots and 50 waiting, the second carries only those that were waiting.
		assert_near(peer.priority[2], 1.0, 1e-9, "those that do not fit this time accumulate the weight")


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
			"with weights equal to the id, the %d with the highest weight go out" % CAPACITY)
	assert_near(peer.priority[10], 10.0, 1e-9, "an unsent one accumulates its weight")
	assert_near(peer.priority[100], 0.0, 1e-9, "a sent one goes back to 0")


func test_priority_matches_a_reference_model_over_many_snapshots() -> void:
	# Independent reference model: accumulate, sort by (priority desc, id asc) with
	# sort_custom, take the first C and reset the sent ones to 0.
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
			fail("snapshot %d does not match the reference model" % snapshot_index)
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
		assert_true(packet.size() <= MAX_BYTES, "tick %d: at most 1200 B" % tick)
		var snapshot: NetMessages.Snapshot = _decode(packet)
		assert_eq(snapshot.records.size(), CAPACITY, "%d records" % CAPACITY)
		assert_true(_record_ids(snapshot).has(2) and _record_ids(snapshot).has(5),
				"huge weights always go out")
	for net_id: int in peer.priority:
		assert_false(is_nan(peer.priority[net_id]), "the priority of %d is not NaN" % net_id)
		assert_true(peer.priority[net_id] >= 0.0, "nor negative (%d)" % net_id)


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
	assert_eq(packets.size(), 30, "one packet per peer")
	for entity: CountingEntity in counted:
		assert_eq(entity.encode_calls, 1, "entity %d was encoded only once" % entity.net_id)
	builder.begin(2, all)
	for entity: CountingEntity in counted:
		assert_eq(entity.encode_calls, 2, "and once more on the next tick")


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


# --- Property test: 200 entities, 600 ticks ---------------------------------------------------

## An observer of the property test.
class Observer:
	var peer: ServerPeer
	## Maximum consecutive snapshots that a relevant entity goes without being sent.
	var max_wait: int = 0
	## Maximum candidates (relevant and existing) it has had at once.
	var max_candidates: int = 0
	var waiting: Dictionary = {}
	var snapshots: int = 0


func test_property_200_entities_600_ticks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260601
	var registry := NetEntityRegistry.new()
	var players: Array[NetEntity] = _spawn_players(registry, rng, 200)
	var builder := SnapshotBuilder.new(InterestPolicy.new())

	# A sees everyone; B sees a subset that changes every 25 ticks; C sees 30 plus the 15 that enter
	# (all fit: CAPACITY is 50 with the 111 B state).
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
		# Some entities leave and enter: their ids stay as relevant for a while.
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
			# Wait of each candidate: consecutive snapshots as relevant without being sent.
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
	assert_eq(oversize, 0, "no packet exceeds 1200 B")
	assert_eq(undecodable, 0, "all decode with NetMessages.Snapshot.decode")
	assert_eq(own_leaks, 0, "the player themselves never appears among the records")
	assert_eq(duplicates, 0, "no repeated record within a packet")
	assert_eq(record_mismatches, 0, "each record matches its entity's position")
	for observer: Observer in observers:
		var bound: int = ceili(observer.max_candidates / float(CAPACITY))
		assert_eq(observer.snapshots, 600, "600 snapshots")
		assert_true(observer.max_wait <= bound,
				("ninguna entidad pasa más de ceil(N/C) = %d snapshots sin enviarse "
				+ "(N = %d, C = %d): máximo observado %d")
				% [bound, observer.max_candidates, CAPACITY, observer.max_wait])
	assert_true(observer_a.max_candidates >= 199, "observer A got to see 199")
	assert_true(observer_a.max_wait >= 1,
			"with 199 candidates and %d slots some had to wait" % CAPACITY)
	assert_true(observer_c.max_candidates <= CAPACITY,
			"C never has more candidates than slots (%d of %d)" % [observer_c.max_candidates, CAPACITY])
	assert_eq(observer_c.max_wait, 0, "with all its candidates fitting, none waits")
