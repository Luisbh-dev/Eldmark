class_name SnapshotBuilder
extends RefCounted
## Construye los SNAPSHOT de cada cliente (docs/red.md, sección 9.3).
## [br][br]
## [method begin] se llama una vez por tick: codifica [b]cada registro una sola vez[/b] en un
## búfer compartido y guarda su offset por [code]net_id[/code]. Codificar es O(entidades); por
## cliente solo hay copias de memoria. [method build_for] arma el paquete de un peer:
## [codeblock]
## cabecera  tick, input_ack_tick, input_margin, sustituciones, estado propio y su contador
##           de teletransporte
## candidatas  las entidades de peer.relevant menos la propia; a cada una se le suma
##             peer.priority[id] += policy.priority_weight(observador, entidad)
## selección   si caben todas en MAX_PACKET_BYTES se escriben todas; si no, las de mayor
##             prioridad (desempate por net_id) hasta llenar el presupuesto
## escritura   las escritas vuelven a prioridad 0; los registros van agrupados por kind en
##             secciones y, dentro de cada una, por net_id ascendente
## [/codeblock]
## El paquete nunca pasa de [constant NetProtocol.MAX_PACKET_BYTES]. Como lo que no se envía
## acumula prioridad y lo que se envía vuelve a cero, con N candidatas y C plazas ninguna pasa más
## de ceil(N / C) snapshots sin enviarse (con los pesos de la fase 2, todos 1,0).

## Bytes de la cabecera de cada sección: kind y número de registros.
const SECTION_HEADER_SIZE: int = 2
## Los tipos que viajan como registro de flujo en un snapshot, en el orden de sus secciones.
const _STREAM_KINDS: Array[int] = [NetProtocol.EntityKind.PLAYER, NetProtocol.EntityKind.NPC]
## La prioridad se compara como entero con esta resolución (una millonésima), que junto con el
## id de 16 bits cabe en un entero de 64 bits y se ordena con la ordenación nativa.
const _SCORE_SCALE: float = 1048576.0
const _MAX_SCORE: int = (1 << 43) - 1
const _ID_MASK: int = 0xFFFF

var _policy: InterestPolicy
var _tick: int = 0
# Registros de todas las entidades del tick, uno detrás de otro (EntityRecord.SIZE bytes cada uno).
var _records: PackedByteArray = PackedByteArray()
# net_id -> offset de su registro en _records.
var _offsets: Dictionary[int, int] = {}
# net_id -> entidad (para el kind y para la política).
var _entities: Dictionary[int, NetEntity] = {}


## [param policy] da el peso de prioridad de cada entidad para cada observador. null = la base.
func _init(policy: InterestPolicy) -> void:
	_policy = policy if policy != null else InterestPolicy.new()


## Codifica una vez los registros de [param entities] (que son las del tick [param tick]).
## Solo los tipos que viajan como registro de flujo (jugadores y PNJ) entran en un snapshot.
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


## El SNAPSHOT de [param peer]: nunca más de [constant NetProtocol.MAX_PACKET_BYTES]. Consume
## [method InputQueue.pop_min_lead] de la cola del peer (la antelación mínima desde el snapshot
## anterior) y actualiza [member ServerPeer.priority].
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
		# -128 solo significa «sin datos»: una antelación muy negativa se satura a -127.
		input_margin = lead if lead == NetProtocol.NO_MARGIN else clampi(lead, -127, 127)
		substitutions = queue.substitutions_total & 0xFFFF
	var teleport_counter: int = observer.teleport_counter if observer != null else 0

	var packet := PackedByteArray()
	var section_offset: int = NetMessages.Snapshot.write_header(packet, _tick, input_ack_tick,
			input_margin, substitutions, teleport_counter, own_state_bytes)

	# Candidatas y acumulador de prioridad.
	var candidates := PackedInt32Array()
	var kinds_present: int = 0
	for net_id: int in peer.relevant:
		if not peer.relevant[net_id] or net_id == own_id or not _offsets.has(net_id):
			continue
		var entity: NetEntity = _entities[net_id]
		candidates.append(net_id)
		kinds_present |= 1 << entity.kind
		var weight: float = _policy.priority_weight(observer, entity)
		# Un peso negativo o NaN no resta prioridad: cuenta como 0.
		var safe_weight: float = weight if weight > 0.0 else 0.0
		var accumulated: float = peer.priority.get(net_id, 0.0)
		peer.priority[net_id] = accumulated + safe_weight
	if peer.priority.size() > candidates.size():
		_prune_priority(peer, own_id)

	# Presupuesto: lo que queda del paquete tras la cabecera y las cabeceras de sección.
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

	# Secciones por kind, con los registros por net_id ascendente.
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


# Los [param capacity] ids de [param candidates] con más prioridad; a igual prioridad, los de
# menor net_id. Ordena enteros de 64 bits (prioridad en los bits altos, id invertido en los
# 16 bajos) con la ordenación nativa en vez de llamar a un comparador por cada par.
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


# Borra del acumulador lo que ya no es candidata (dejó de ser relevante o desapareció).
func _prune_priority(peer: ServerPeer, own_id: int) -> void:
	for net_id: int in peer.priority.keys():
		if not peer.relevant.get(net_id, false) or net_id == own_id or not _offsets.has(net_id):
			peer.priority.erase(net_id)
