class_name StateLogDiffer
extends RefCounted
## Compares two SERVER state logs of the same seeded scenario that ran on different machines (TEC-12: Linux against
## Windows, docs/networking.md section 14). Unlike [StateLogComparer], which cross-checks a server with its bot, this
## looks for floating point drift between platforms: each line is [code]tick,net_id,substituted,hex(state)[/code]
## and the lines are matched by [code](tick, net_id)[/code].
## [br][br]
## The encoded state is read as 32-bit words and the distance of a word is the difference of its bits as an integer
## (for a float32 of the same sign that is the number of ULPs). The distance of a line is its largest word distance:
## [br]- [b]last bit[/b]: 1 (the rounding noise of a different libm or instruction mix);
## [br]- [b]drift[/b]: 2 to [constant DRIFT_MAX_ULPS] (that noise integrated over a few ticks);
## [br]- [b]larger[/b]: beyond that (a discrete decision went the other way: a hit, a state change).
## An integer field that differs by one counts as last bit as well: the figures are upper bounds of the rounding noise.
## Once a player diverges it stays diverged (the error feeds the next tick), so the report also gives, for each player,
## the tick of its FIRST difference and how big it was: that is the real measure of how often the platforms disagree.

const MAX_LISTED: int = 10
## Largest distance that still counts as drift.
const DRIFT_MAX_ULPS: int = 16


class Result:
	extends RefCounted

	var error: String = ""
	## Lines present in both logs.
	var compared: int = 0
	var identical: int = 0
	var last_bit: int = 0
	var drift: int = 0
	var larger: int = 0
	## Lines that exist in one log and not in the other.
	var unpaired: int = 0
	## First tick with any difference, -1 if none.
	var first_difference_tick: int = -1
	## First tick with a larger difference, -1 if none.
	var first_larger_tick: int = -1
	var listed: Array[String] = []
	## Players that ever differ, and of those, how many started with a last-bit difference.
	var players_total: int = 0
	var players_diverged: int = 0
	var players_diverged_by_last_bit: int = 0
	## "net_id N: tick T, D ulps" for each player that diverged.
	var first_divergences: Array[String] = []

	## true if the logs could be compared line by line (no error, nothing in only one of them).
	func is_comparable() -> bool:
		return error.is_empty() and unpaired == 0

	## true if the logs are the same bit for bit.
	func is_exact() -> bool:
		return is_comparable() and last_bit == 0 and drift == 0 and larger == 0

	## Fraction of the compared lines that differ at all.
	func difference_rate() -> float:
		return 0.0 if compared == 0 else float(last_bit + drift + larger) / float(compared)

	## Fraction of the compared lines that differ in the last bit only.
	func last_bit_rate() -> float:
		return 0.0 if compared == 0 else float(last_bit) / float(compared)

	func summary() -> String:
		if not error.is_empty():
			return "Cannot compare: %s" % error
		var lines: PackedStringArray = PackedStringArray()
		lines.append("State log diff (A against B)")
		lines.append("  Lines compared ................ %d" % compared)
		lines.append("  Identical ..................... %d" % identical)
		lines.append("  Last-bit differences (1 ulp) . %d (%.4f%%)" % [last_bit, last_bit_rate() * 100.0])
		lines.append("  Drift (2 to %d ulps) .......... %d" % [DRIFT_MAX_ULPS, drift])
		lines.append("  Larger differences ............ %d" % larger)
		lines.append("  Lines that differ ............. %.4f%%" % (difference_rate() * 100.0))
		lines.append("  Lines in only one log ......... %d" % unpaired)
		lines.append("  First difference at tick ...... %d" % first_difference_tick)
		lines.append("  First larger difference at .... %d" % first_larger_tick)
		lines.append("  Players that diverge .......... %d of %d (%d of them started with a last-bit difference)" % [
				players_diverged, players_total, players_diverged_by_last_bit])
		for entry: String in first_divergences:
			lines.append("    " + entry)
		lines.append("Result: %s" % ("IDENTICAL" if is_exact() else ("COMPARED, THEY DIFFER" if is_comparable() else "NOT COMPARABLE")))
		return "\n".join(lines)


## Compares the two files.
static func compare_files(path_a: String, path_b: String) -> Result:
	var result: Result = Result.new()
	if not FileAccess.file_exists(path_a) or not FileAccess.file_exists(path_b):
		result.error = "a log is missing (%s, %s)" % [path_a, path_b]
		return result
	return compare_texts(FileAccess.get_file_as_string(path_a), FileAccess.get_file_as_string(path_b))


## Compares the text of two logs.
static func compare_texts(text_a: String, text_b: String) -> Result:
	var result: Result = Result.new()
	var a: Dictionary = _index(text_a)
	var b: Dictionary = _index(text_b)
	if a.is_empty() or b.is_empty():
		result.error = "a log has no lines"
		return result
	var keys: Array = a.keys()
	keys.sort_custom(func(left: String, right: String) -> bool: return _tick_of(left) < _tick_of(right))
	var players: Dictionary = {}
	for key: Variant in keys:
		if not b.has(key):
			result.unpaired += 1
			continue
		result.compared += 1
		var state_a: String = a[key]
		var state_b: String = b[key]
		if state_a == state_b:
			result.identical += 1
			continue
		var tick: int = _tick_of(str(key))
		var net_id: String = str(key).get_slice(":", 1)
		var distance: int = _distance(state_a, state_b)
		if result.first_difference_tick < 0 or tick < result.first_difference_tick:
			result.first_difference_tick = tick
		if distance <= 1:
			result.last_bit += 1
		elif distance <= DRIFT_MAX_ULPS:
			result.drift += 1
		else:
			result.larger += 1
			if result.first_larger_tick < 0 or tick < result.first_larger_tick:
				result.first_larger_tick = tick
		if not players.has(net_id):
			players[net_id] = true
			result.players_diverged += 1
			if distance <= 1:
				result.players_diverged_by_last_bit += 1
			if result.first_divergences.size() < MAX_LISTED * 2:
				result.first_divergences.append("net_id %s: tick %d, %d ulps" % [net_id, tick, distance])
	for key: Variant in b.keys():
		if not a.has(key):
			result.unpaired += 1
	var ids: Dictionary = {}
	for key: Variant in a.keys():
		ids[str(key).get_slice(":", 1)] = true
	result.players_total = ids.size()
	return result


static func _index(text: String) -> Dictionary:
	var lines: Dictionary = {}
	for line: String in text.split("\n", false):
		var parts: PackedStringArray = line.strip_edges().split(",")
		if parts.size() != 4 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		lines["%s:%s" % [parts[0], parts[1]]] = parts[3]
	return lines


## The largest distance between the 32-bit words of two hexadecimal states; a different length is infinite.
static func _distance(hex_a: String, hex_b: String) -> int:
	if hex_a.length() != hex_b.length() or hex_a.length() % 2 != 0:
		return 1 << 40
	var largest: int = 0
	for offset: int in range(0, hex_a.length(), 8):
		var word_a: String = hex_a.substr(offset, 8)
		var word_b: String = hex_b.substr(offset, 8)
		if word_a != word_b:
			largest = maxi(largest, absi(_word(word_a) - _word(word_b)))
	return largest


static func _tick_of(key: String) -> int:
	return int(key.get_slice(":", 0))


## The word (up to four bytes; the last one of a state may be shorter) as the integer of its little-endian bytes.
static func _word(hex: String) -> int:
	var bytes: PackedByteArray = hex.hex_decode()
	var value: int = 0
	for index: int in bytes.size():
		value |= bytes[index] << (8 * index)
	return value
