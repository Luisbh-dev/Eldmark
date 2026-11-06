class_name StateLogDiffer
extends RefCounted
## Compares two SERVER state logs of the same seeded scenario that ran on different machines (TEC-12: Linux against
## Windows, docs/networking.md section 14). Unlike [StateLogComparer], which cross-checks a server with its bot, this
## looks for floating point drift between platforms: each line is [code]tick,net_id,substituted,hex(state)[/code]
## and the lines are matched by [code](tick, net_id)[/code].
## [br][br]
## The encoded state is read as 32-bit words. A line that differs is [b]last bit[/b] if every word that
## differs is at most one unit apart as an integer (for a float32 that is one ULP, the rounding noise of a different
## libm or instruction mix); otherwise it is a [b]larger[/b] difference. An integer field that differs by one is
## counted as last bit as well: the figure is an upper bound of the rounding noise.

const MAX_LISTED: int = 10


class Result:
	extends RefCounted

	var error: String = ""
	## Lines present in both logs.
	var compared: int = 0
	var identical: int = 0
	var last_bit: int = 0
	var larger: int = 0
	## Lines that exist in one log and not in the other.
	var unpaired: int = 0
	## First tick with any difference, -1 if none.
	var first_difference_tick: int = -1
	## First tick with a larger difference, -1 if none.
	var first_larger_tick: int = -1
	var listed: Array[String] = []

	func is_ok() -> bool:
		return error.is_empty() and larger == 0 and unpaired == 0

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
		lines.append("  Last-bit differences .......... %d (%.4f%%)" % [last_bit, last_bit_rate() * 100.0])
		lines.append("  Larger differences ............ %d" % larger)
		lines.append("  Lines in only one log ......... %d" % unpaired)
		lines.append("  First difference at tick ...... %d" % first_difference_tick)
		lines.append("  First larger difference at .... %d" % first_larger_tick)
		for entry: String in listed:
			lines.append("    " + entry)
		lines.append("Result: %s" % ("OK (at most last-bit noise)" if is_ok() else "DIFFERENCES"))
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
		var tick: int = int(str(key).get_slice(":", 0))
		if result.first_difference_tick < 0 or tick < result.first_difference_tick:
			result.first_difference_tick = tick
		if _only_last_bit(state_a, state_b):
			result.last_bit += 1
		else:
			result.larger += 1
			if result.first_larger_tick < 0 or tick < result.first_larger_tick:
				result.first_larger_tick = tick
			if result.listed.size() < MAX_LISTED:
				result.listed.append("tick %d net_id %s" % [tick, str(key).get_slice(":", 1)])
	for key: Variant in b.keys():
		if not a.has(key):
			result.unpaired += 1
	return result


static func _index(text: String) -> Dictionary:
	var lines: Dictionary = {}
	for line: String in text.split("\n", false):
		var parts: PackedStringArray = line.strip_edges().split(",")
		if parts.size() != 4 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		lines["%s:%s" % [parts[0], parts[1]]] = parts[3]
	return lines


## true if the two hexadecimal states have the same length and every 32-bit word that differs is one unit apart.
static func _only_last_bit(hex_a: String, hex_b: String) -> bool:
	if hex_a.length() != hex_b.length() or hex_a.length() % 8 != 0:
		return false
	for offset: int in range(0, hex_a.length(), 8):
		var word_a: String = hex_a.substr(offset, 8)
		var word_b: String = hex_b.substr(offset, 8)
		if word_a == word_b:
			continue
		if absi(_word(word_a) - _word(word_b)) > 1:
			return false
	return true


## The 32-bit word as the integer of its little-endian bytes (the encoding is little-endian).
static func _word(hex: String) -> int:
	var bytes: PackedByteArray = hex.hex_decode()
	if bytes.size() != 4:
		return 0
	return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
