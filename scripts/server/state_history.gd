class_name StateHistory
extends RefCounted
## Position history for lag compensation (docs/networking.md, section 10).
## [br][br]
## It stores, per entity, a track of [constant LENGTH_TICKS] ticks (~1 s) in packed arrays: position, yaw, flags and the
## tick label of each slot, indexed by [code]tick % LENGTH_TICKS[/code]. The track is created when the entity is
## registered and is written in place every tick, without allocating memory. Values are stored unquantized and recorded
## after every tick, whether or not there is interest.
## [br][br]
## [method sample] reconstructs any instant (also between two ticks) so that phase 3 checks hits against where the
## attacker saw their target. Bodies are never moved backwards: it is computed from the samples.
## [br][br]
## [b]Flags.[/b] The flags of each slot are bits 0-2 of the network record (bit 0 ground, bits 1-2 teleport counter;
## [constant EntityRecord.HISTORY_FLAGS_MASK]) plus the defensive flags of [method ActionMachine.defense_flags] (bit 3
## blocking, bit 4 parry window, bit 5 invulnerable, bit 6 dead, bit 7 shield wall's wide block), used by the
## [CombatResolver] to decide whether a rewound hit is blocked, parried or dodged. Bit 3 of the network record (weapon
## slot 2, docs/abilities.md, section 5.2) [b]never[/b] goes in: here bit 3 is [constant ActionMachine.DEFENSE_BLOCKING];
## whoever records masks the record's flags.
## [br][br]
## [b]Projectiles[/b] (docs/abilities.md, section 4.4): [method position_at] reads the position of an exact tick
## without creating objects (projectile rewind is in whole ticks) and each track maintains, when recording,
## [constant SWEPT_BLOCKS] boxes of [constant SWEPT_BLOCK_TICKS] ticks with the feet positions: [method swept_box] is
## their union, the cheap screening of an arrow's candidates.

## Ticks each track remembers. A power of 2 to index with a mask.
const LENGTH_TICKS: int = 64
## Ticks in each swept box block (a power of 2: a tick's block is [code]tick >> 3[/code]).
const SWEPT_BLOCK_TICKS: int = 8
## Blocks each track keeps (a power of 2): that of the last recorded tick and the three before cover at least its
## previous 25 ticks, more than the rewind cap (24).
const SWEPT_BLOCKS: int = 4
const _SWEPT_BLOCK_SHIFT: int = 3

# net_id -> track.
var _tracks: Dictionary[int, Track] = {}


## Result of [method sample]: position, yaw and flags of the entity at that instant.
class Sample:
	var position: Vector3
	var yaw: float
	## Bits 0-2 of the network record (bit 0 grounded; bits 1-2 teleport counter) and defensive bits 3-7
	## ([method ActionMachine.defense_flags]).
	var flags: int


## Track of an entity.
class Track:
	var positions: PackedVector3Array = PackedVector3Array()
	var yaws: PackedFloat32Array = PackedFloat32Array()
	var flags: PackedByteArray = PackedByteArray()
	# Tick stored in each slot; -1 if empty. 64-bit: server ticks are u32 and exceed 2^31 after 414 days of process uptime.
	var ticks: PackedInt64Array = PackedInt64Array()
	# Swept boxes by blocks of SWEPT_BLOCK_TICKS ticks: the block each slot holds (-1 empty) and the minimum and maximum
	# corner of the positions recorded in it.
	var block_ids: PackedInt64Array = PackedInt64Array()
	var block_min: PackedVector3Array = PackedVector3Array()
	var block_max: PackedVector3Array = PackedVector3Array()
	# Block of the last recorded tick (-1 = none) and the union of the boxes of the blocks that count (the last one and the
	# SWEPT_BLOCKS - 1 before it), kept up to date on each recording: swept_box walks nothing.
	var last_block: int = -1
	var union_min: Vector3 = Vector3.ZERO
	var union_max: Vector3 = Vector3.ZERO


	func _init() -> void:
		positions.resize(LENGTH_TICKS)
		yaws.resize(LENGTH_TICKS)
		flags.resize(LENGTH_TICKS)
		ticks.resize(LENGTH_TICKS)
		ticks.fill(-1)
		block_ids.resize(SWEPT_BLOCKS)
		block_ids.fill(-1)
		block_min.resize(SWEPT_BLOCKS)
		block_max.resize(SWEPT_BLOCKS)


	# Writes a slot in place and extends its block's box. It lives inside the track (and not in StateHistory) so that the
	# arrays are modified directly and not through a temporary copy.
	func write(slot: int, tick: int, position: Vector3, yaw: float, flags_byte: int) -> void:
		positions[slot] = position
		yaws[slot] = yaw
		flags[slot] = flags_byte
		ticks[slot] = tick
		var block: int = tick >> _SWEPT_BLOCK_SHIFT
		var block_slot: int = block & (SWEPT_BLOCKS - 1)
		if block_ids[block_slot] != block:
			block_ids[block_slot] = block
			block_min[block_slot] = position
			block_max[block_slot] = position
		else:
			block_min[block_slot] = block_min[block_slot].min(position)
			block_max[block_slot] = block_max[block_slot].max(position)
		if block > last_block:
			# New block: the union is rebuilt with it and the previous ones that still count (every 8 ticks).
			last_block = block
			union_min = position
			union_max = position
			for other: int in SWEPT_BLOCKS:
				var other_block: int = block_ids[other]
				if other_block >= 0 and other_block < block and block - other_block < SWEPT_BLOCKS:
					union_min = union_min.min(block_min[other])
					union_max = union_max.max(block_max[other])
		elif last_block - block < SWEPT_BLOCKS:
			union_min = union_min.min(position)
			union_max = union_max.max(position)


## Creates the track of [param net_id] (empty). If it already existed, it is erased.
func add_entity(net_id: int) -> void:
	_tracks[net_id] = Track.new()


## Deletes the track of [param net_id].
func forget(net_id: int) -> void:
	_tracks.erase(net_id)


## Records the state of [param net_id] after simulating [param tick]. Overwrites the slot of tick
## [code]tick - LENGTH_TICKS[/code]. If the entity had no track, it is created. Does nothing with a negative tick.
func record(tick: int, net_id: int, position: Vector3, yaw: float, flags: int) -> void:
	if tick < 0:
		return
	var track: Track = _tracks.get(net_id)
	if track == null:
		track = Track.new()
		_tracks[net_id] = track
	track.write(tick & (LENGTH_TICKS - 1), tick, position, yaw, flags & 0xFF)


## true if the track of [param net_id] stores exactly tick [param tick].
func has_tick(net_id: int, tick: int) -> bool:
	var track: Track = _tracks.get(net_id)
	return track != null and tick >= 0 and track.ticks[tick & (LENGTH_TICKS - 1)] == tick


## Flags of [param net_id] at the exact tick [param tick], or -1 if that tick is not recorded (the entity has no track,
## the tick is older than the ring or newer than the last recorded).
func get_flags(net_id: int, tick: int) -> int:
	var track: Track = _tracks.get(net_id)
	if track == null or tick < 0:
		return -1
	var slot: int = tick & (LENGTH_TICKS - 1)
	if track.ticks[slot] != tick:
		return -1
	return track.flags[slot]


## Position (the feet) of [param net_id] at the exact tick [param tick], or [constant Vector3.INF] if that tick is not
## recorded. It creates no object: it is the projectiles' read, which rewind whole ticks (docs/abilities.md, section
## 4.4).
func position_at(net_id: int, tick: int) -> Vector3:
	var track: Track = _tracks.get(net_id)
	if track == null or tick < 0:
		return Vector3.INF
	var slot: int = tick & (LENGTH_TICKS - 1)
	if track.ticks[slot] != tick:
		return Vector3.INF
	return track.positions[slot]


## Swept box of [param net_id]: the union of the boxes of the [constant SWEPT_BLOCKS] blocks of
## [constant SWEPT_BLOCK_TICKS] ticks ending at the last recorded tick's (older ones do not count). If that tick is
## [code]s − 1[/code], it covers all recorded positions from [code][s − 25, s − 1][/code] (and some older one). These
## are the feet: whoever uses it widens it with the capsule. With nothing recorded, a box of negative size
## ([code]size.x < 0[/code]).
func swept_box(net_id: int) -> AABB:
	var track: Track = _tracks.get(net_id)
	if track == null or track.last_block < 0:
		return AABB(Vector3.ZERO, -Vector3.ONE)
	return AABB(track.union_min, track.union_max - track.union_min)


## State of [param net_id] at the instant [param tick] (may be fractional): interpolates linearly between the two
## surrounding ticks (position with lerp, yaw with lerp_angle and flags from the nearest). If the teleport counter
## changes between the two, it returns the earlier sample without interpolating. null if the entity has no track or the
## instant is outside what was recorded (older than the ring, or newer than the last tick).
func sample(net_id: int, tick: float) -> StateHistory.Sample:
	var track: Track = _tracks.get(net_id)
	if track == null or not is_finite(tick) or tick < 0.0:
		return null
	var floor_tick: int = floori(tick)
	var fraction: float = tick - float(floor_tick)
	var slot_a: int = floor_tick & (LENGTH_TICKS - 1)
	if track.ticks[slot_a] != floor_tick:
		return null
	if fraction <= 0.0:
		return _make_sample(track, slot_a)
	var slot_b: int = (floor_tick + 1) & (LENGTH_TICKS - 1)
	if track.ticks[slot_b] != floor_tick + 1:
		return null
	var flags_a: int = track.flags[slot_a]
	var flags_b: int = track.flags[slot_b]
	if _teleport_counter(flags_a) != _teleport_counter(flags_b):
		return _make_sample(track, slot_a)
	var result := Sample.new()
	result.position = track.positions[slot_a].lerp(track.positions[slot_b], fraction)
	result.yaw = lerp_angle(track.yaws[slot_a], track.yaws[slot_b], fraction)
	result.flags = flags_a if fraction < 0.5 else flags_b
	return result


static func _make_sample(track: Track, slot: int) -> Sample:
	var result := Sample.new()
	result.position = track.positions[slot]
	result.yaw = track.yaws[slot]
	result.flags = track.flags[slot]
	return result


static func _teleport_counter(flags: int) -> int:
	return (flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK
