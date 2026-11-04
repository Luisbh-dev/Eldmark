class_name IdAllocator
extends RefCounted
## The zone's ids (docs/progression.md §4.5): the object [code]uid[/code]s and the [code]op_id[/code]s of
## operations come from the same generator. With a platform, from the blocks of 1024 that
## [code]POST /internal/v1/id-blocks[/code] gives ([method ZonePlatform.request_id_block], platform.md §6), unique across
## all worlds; without a platform, [method local] counts from 1 in memory (nothing is saved).
## [br][br]
## [b]Three bands[/b], from the bottom up in what remains:
## [codeblock]
## the last build_reserve (2 × max_players)      only next_for_build: closing what was added when building a save
## the SERVER_RESERVE above that                 next_for_server: kit, new CAMP_REFILL stack, closing before a
##                                               one-off operation, GM and reversal
## the rest                                      next_for_client: client SPLIT and DESTROY
## [/codeblock]
## This way no client leaves another unable to drink or the zone unable to save: with the platform down nothing goes out except the
## save in flight, nobody new enters and each character builds at most two bodies, which the reserve covers.
## It keeps at most two blocks (it requests another when fewer than [constant REFILL_BELOW] remain above the saves'
## reserve) and spends them in order. A half-used block lost in a crash leaves a gap: nothing is
## ever repeated. Server only: no clock.

## Warns when, after taking an id, [method needs_block] is true: whoever listens requests the next block.
signal running_low

## Ids in each platform block.
const BLOCK_SIZE: int = 1024
## Another block is requested when fewer than this remain above [member build_reserve].
const REFILL_BELOW: int = 512
## Ids in the server's band, above [member build_reserve].
const SERVER_RESERVE: int = 256
## Highest id (2^53 − 1: a JSON number carries it exactly, §3.4).
const MAX_ID: int = (1 << 53) - 1

## The saves' band: 2 × [code]max_players[/code] (128 with 64 slots); set by
## [method ProgressService.setup].
var build_reserve: int = 128

## Blocks that remain: [code][next, last][/code] (both included), in the order they arrived.
var _blocks: Array[PackedInt64Array] = []
## Without a platform: counts from 1 with no cap or bands.
var _local: bool = false
var _local_next: int = 1
var _taken: int = 0


## The generator without a platform: from 1, in memory, with no blocks or bands (all characters are ephemeral).
static func local() -> IdAllocator:
	var ids := IdAllocator.new()
	ids._local = true
	return ids


## true if it is the one from [method local].
func is_local() -> bool:
	return _local


## Adds the block [code][first, first + count)[/code] given by the platform. A block that is not valid (empty,
## outside 1 … 2^53 − 1 or overlapping one that remains) is ignored with a warning: it is a platform error.
func add_block(first: int, count: int) -> void:
	if _local:
		return
	if first < 1 or count < 1 or count > MAX_ID or first > MAX_ID - count + 1:
		push_warning("[Eldmark] Ids: bloque que no vale (%d, %d)" % [first, count])
		return
	var last: int = first + count - 1
	for block: PackedInt64Array in _blocks:
		if first <= block[1] and last >= block[0]:
			push_warning("[Eldmark] Ids: el bloque (%d, %d) se solapa con uno que queda" % [first, count])
			return
	_blocks.append(PackedInt64Array([first, last]))


## true if another block must be requested: fewer than [member build_reserve] + [constant REFILL_BELOW] remain.
func needs_block() -> bool:
	return not _local and available() < build_reserve + REFILL_BELOW


## Ids remaining in the blocks (without a platform, those remaining up to 2^53 − 1).
func available() -> int:
	if _local:
		return MAX_ID - _local_next + 1
	var total: int = 0
	for block: PackedInt64Array in _blocks:
		total += block[1] - block[0] + 1
	return total


## An id for a client request (SPLIT, DESTROY); 0 if [member build_reserve] +
## [constant SERVER_RESERVE] or fewer remain.
func next_for_client() -> int:
	return _take(build_reserve + SERVER_RESERVE)


## An id for the rest of the server (kit, CAMP_REFILL, closing before a one-off operation, GM, reversal); 0 if
## [member build_reserve] or fewer remain.
func next_for_server() -> int:
	return _take(build_reserve)


## An id for closing what was added when building a save ([method PlayerProgress.build_section]); 0 if none
## remain.
func next_for_build() -> int:
	return _take(0)


## Ids that have been given out since it came into existence (metrics and tests).
func taken_count() -> int:
	return _taken


# The next id if more than [param keep] remain; 0 otherwise.
func _take(keep: int) -> int:
	if _local:
		if _local_next > MAX_ID:
			return 0
		_local_next += 1
		_taken += 1
		return _local_next - 1
	if available() <= keep or _blocks.is_empty():
		return 0
	var block: PackedInt64Array = _blocks[0]
	var id: int = block[0]
	if block[0] == block[1]:
		_blocks.remove_at(0)
	else:
		block[0] += 1
		_blocks[0] = block
	_taken += 1
	if needs_block():
		running_low.emit()
	return id
