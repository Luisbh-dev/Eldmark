class_name SnapshotBuilder
extends RefCounted
## Builds each client's SNAPSHOTs (docs/networking.md, section 9.3).
## [br][br]
## [method begin] is called once per tick: it encodes [b]each record only once[/b] in a shared buffer and stores its
## offset per [code]net_id[/code]. Encoding is O(entities); per client there are only memory copies. [method build_for]
## assembles a peer's packet:
## [codeblock]
## header      tick, input_ack_tick, input_margin, substitutions, own state, its teleport
##             counter and the own extra block (health, max health, state and respawn tick,
##             from NetEntity.health and company)
## candidates  the entities of peer.relevant minus its own; each one gets
##             peer.priority[id] += policy.priority_weight(observer, entity)
## selection   if all fit in MAX_PACKET_BYTES all are written; otherwise, those with the highest
##             priority (ties broken by net_id) until the budget is filled
## writing     the written ones go back to priority 0; records are grouped by kind into
##             sections and, within each one, by ascending net_id
## [/codeblock]
## The packet never exceeds [constant NetProtocol.MAX_PACKET_BYTES]. Since what is not sent accumulates priority and what
## is sent goes back to zero, with N candidates and C slots none goes more than ceil(N / C) snapshots without being sent
## (with the phase 2 weights, all 1.0).

## Bytes of each section's header: kind and number of records.
const SECTION_HEADER_SIZE: int = 2
## The kinds that travel as a stream record in a snapshot, in the order of their sections.
const _STREAM_KINDS: Array[int] = [NetProtocol.EntityKind.PLAYER, NetProtocol.EntityKind.NPC]
## Priority is compared as an integer with this resolution (one millionth), which together with the 16-bit id fits in a
## 64-bit integer and is sorted with the native sort.
const _SCORE_SCALE: float = 1048576.0
const _MAX_SCORE: int = (1 << 43) - 1
const _ID_MASK: int = 0xFFFF

var _policy: InterestPolicy
var _tick: int = 0
# Records of all the tick's entities, one after another (EntityRecord.SIZE bytes each).
var _records: PackedByteArray = PackedByteArray()
# net_id -> offset of its record in _records.
var _offsets: Dictionary[int, int] = {}
# net_id -> entity (for the kind and for the policy).
var _entities: Dictionary[int, NetEntity] = {}


## [param policy] gives the priority weight of each entity for each observer. null = the base one.
func _init(policy: InterestPolicy) -> void:
	_policy = policy if policy != null else InterestPolicy.new()


## Encodes once the records of [param entities] (which are those of tick [param tick]). Only the kinds that travel as a
## stream record (players and NPCs) go into a snapshot.
func begin(tick: int, entities: Array[NetEntity]) -> void:
	_tick = tick
	_offsets.clear()
	_entities.clear()
	var needed: int = entities.size() * EntityRecord.SIZE
	if _records.size() < needed:
		_records.resize(needed)
	var offset: int = 0
	for entity: NetEntity in entities:
		if not _STREAM_KINDS.has(entity.kind):
			continue
		entity.encode_record(_records, offset)
		_offsets[entity.net_id] = offset
		_entities[entity.net_id] = entity
		offset += EntityRecord.SIZE


## The SNAPSHOT of [param peer]: never more than [constant NetProtocol.MAX_PACKET_BYTES]. Consumes
## [method InputQueue.pop_min_lead] from the peer's queue (the minimum lead since the previous snapshot) and updates
## [member ServerPeer.priority].
func build_for(peer: ServerPeer) -> PackedByteArray:
	var observer: NetEntity = peer.entity
	var own_id: int = observer.net_id if observer != null else 0
	var own_state_bytes := PackedByteArray()
	if observer != null:
		var character: PlayerCharacter = observer.get_character()
		if character != null:
			own_state_bytes = character.get_state().encode()

	var input_ack_tick: int = 0
	var input_margin: int = NetProtocol.NO_MARGIN
	var substitutions: int = 0
	var queue: InputQueue = peer.input_queue
	if queue != null:
		input_ack_tick = queue.get_ack_tick()
		var lead: int = queue.pop_min_lead()
		# -128 only means "no data": a very negative lead saturates at -127.
		input_margin = lead if lead == NetProtocol.NO_MARGIN else clampi(lead, -127, 127)
		substitutions = queue.substitutions_total & 0xFFFF
	var teleport_counter: int = observer.teleport_counter if observer != null else 0

	var packet := PackedByteArray()
	# The own extra block comes from the entity itself (NetEntity.set_health_view).
	var section_offset: int = NetMessages.Snapshot.write_header(packet, _tick, input_ack_tick,
			input_margin, substitutions, teleport_counter, own_state_bytes,
			observer.health if observer != null else 0,
			observer.max_health if observer != null else 0,
			observer.status if observer != null else 0,
			observer.respawn_tick if observer != null else 0)

	# Candidates and priority accumulator.
	var candidates := PackedInt32Array()
	var kinds_present: int = 0
	for net_id: int in peer.relevant:
		if not peer.relevant[net_id] or net_id == own_id or not _offsets.has(net_id):
			continue
		var entity: NetEntity = _entities[net_id]
		candidates.append(net_id)
		kinds_present |= 1 << entity.kind
		var weight: float = _policy.priority_weight(observer, entity)
		# A negative or NaN weight does not subtract priority: it counts as 0.
		var safe_weight: float = weight if weight > 0.0 else 0.0
		var accumulated: float = peer.priority.get(net_id, 0.0)
		peer.priority[net_id] = accumulated + safe_weight
	if peer.priority.size() > candidates.size():
		_prune_priority(peer, own_id)

	# Budget: what is left of the packet after the header and the section headers.
	var section_kinds: int = 0
	for kind: int in _STREAM_KINDS:
		if (kinds_present & (1 << kind)) != 0:
			section_kinds += 1
	var budget: int = NetProtocol.MAX_PACKET_BYTES - (section_offset + 1) \
			- SECTION_HEADER_SIZE * section_kinds
	var capacity: int = maxi(floori(float(budget) / float(EntityRecord.SIZE)), 0)
	var chosen: PackedInt32Array = candidates
	if candidates.size() > capacity:
		chosen = _select_top(candidates, peer, capacity)
	chosen.sort()

	# Sections by kind, with records by ascending net_id.
	var by_kind: Array[PackedInt32Array] = []
	for _kind: int in _STREAM_KINDS:
		by_kind.append(PackedInt32Array())
	for net_id: int in chosen:
		by_kind[_STREAM_KINDS.find(_entities[net_id].kind)].append(net_id)
		peer.priority[net_id] = 0.0
	var section_count: int = 0
	for i: int in _STREAM_KINDS.size():
		var ids: PackedInt32Array = by_kind[i]
		if ids.is_empty():
			continue
		packet.append(_STREAM_KINDS[i])
		packet.append(ids.size())
		for net_id: int in ids:
			var offset: int = _offsets[net_id]
			packet.append_array(_records.slice(offset, offset + EntityRecord.SIZE))
		section_count += 1
	packet.encode_u8(section_offset, section_count)
	return packet


# The [param capacity] ids of [param candidates] with the highest priority; at equal priority, those with the lowest
# net_id. Sorts 64-bit integers (priority in the high bits, inverted id in the low 16) with the native sort instead of
# calling a comparator for each pair.
func _select_top(candidates: PackedInt32Array, peer: ServerPeer, capacity: int) -> PackedInt32Array:
	var keys := PackedInt64Array()
	keys.resize(candidates.size())
	for i: int in candidates.size():
		var net_id: int = candidates[i]
		var priority: float = peer.priority[net_id]
		var score: int = int(minf(priority * _SCORE_SCALE, float(_MAX_SCORE)))
		keys[i] = (score << 16) | (_ID_MASK - net_id)
	keys.sort()
	var top := PackedInt32Array()
	for i: int in range(keys.size() - capacity, keys.size()):
		top.append(_ID_MASK - (keys[i] & _ID_MASK))
	return top


# Deletes from the accumulator what is no longer a candidate (it stopped being relevant or disappeared).
func _prune_priority(peer: ServerPeer, own_id: int) -> void:
	for net_id: int in peer.priority.keys():
		if not peer.relevant.get(net_id, false) or net_id == own_id or not _offsets.has(net_id):
			peer.priority.erase(net_id)
