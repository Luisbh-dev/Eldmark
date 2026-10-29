class_name StateLogComparer
extends RefCounted
## Cruza el registro de estados del servidor con el de un bot (docs/red.md, sección 13). La lógica de
## [code]tools/compare_state_logs.gd[/code], separada para poder probarla y para que las pruebas de
## varios procesos la usen sin lanzar otro proceso.
## [br][br]
## Los dos registros son texto, una línea por registro, con los estados en hexadecimal
## ([method PlayerState.encode]):
## [codeblock]
## servidor (--state-log del servidor)   tick,net_id,sustituida,estado        un jugador por línea y tick
## bot      (--state-log del bot)        server_tick,predicho,servidor        una línea por snapshot
## [/codeblock]
## El estado «servidor» del bot es el estado propio de su snapshot, que debe ser idéntico al del
## registro del servidor en ese tick. Cada línea del bot cae en una categoría:
## [br]- [b]coincide[/b]: el estado que predijo el bot es el del servidor, bit a bit;
## [br]- [b]explicada[/b]: no coincide, pero el servidor sustituyó alguna entrada del jugador en los
## ticks que van desde el snapshot anterior del bot (excluido) hasta este (incluido), así que el bot no
## podía saberlo. La reconciliación lo corrige y el siguiente snapshot vuelve a coincidir;
## [br]- [b]sin explicar[/b]: no coincide y no hubo ninguna sustitución. Es un fallo de determinismo (o
## un teletransporte, que el registro del servidor no marca);
## [br]- [b]sin predicción[/b]: el bot no tenía estado predicho para ese tick (reinicio duro de la
## predicción); no se puede comparar y se cuenta aparte.
## [br]Además se cuentan los snapshots cuyo estado propio no es el del registro del servidor en ese tick
## ([member Result.server_mismatches]), los ticks que faltan en el registro del servidor
## ([member Result.missing_ticks]) y las líneas mal formadas ([member Result.malformed_lines]); las tres
## cosas son errores.

## Ticks que se guardan, como mucho, en cada lista de [class Result].
const MAX_LISTED_TICKS: int = 20


## Resultado de una comparación.
class Result:
	extends RefCounted

	## Jugador del servidor con el que se ha comparado el bot.
	var net_id: int = 0
	## Motivo por el que no se pudo comparar ("" si se pudo).
	var error: String = ""
	var bot_lines: int = 0
	var matches: int = 0
	var explained: int = 0
	var unexplained: int = 0
	var unpredicted: int = 0
	var server_mismatches: int = 0
	var missing_ticks: int = 0
	var malformed_lines: int = 0
	var explained_ticks: Array[int] = []
	var unexplained_ticks: Array[int] = []
	var unpredicted_ticks: Array[int] = []
	## true si se pudo comparar y no hay ninguna diferencia sin explicar ni ningún error.
	func is_ok() -> bool:
		return error.is_empty() and unexplained == 0 and server_mismatches == 0 \
				and missing_ticks == 0 and malformed_lines == 0


	## Texto del resumen, en español, para la salida de la herramienta.
	func summary() -> String:
		var lines := PackedStringArray()
		if not error.is_empty():
			lines.append("No se pudo comparar: %s" % error)
			return "\n".join(lines)
		lines.append("Comparación de registros de estado (jugador net_id %d)" % net_id)
		lines.append("  Snapshots del bot ......................... %d" % bot_lines)
		lines.append("  Coinciden exactamente ..................... %d" % matches)
		lines.append("  Diferencias explicadas (entrada sustituida) %d%s" % [explained,
				_ticks_text(explained_ticks, explained)])
		lines.append("  Diferencias sin explicar .................. %d%s" % [unexplained,
				_ticks_text(unexplained_ticks, unexplained)])
		lines.append("  Sin predicción (reinicio duro) ............ %d%s" % [unpredicted,
				_ticks_text(unpredicted_ticks, unpredicted)])
		lines.append("  Estado propio distinto del del servidor ... %d" % server_mismatches)
		lines.append("  Ticks que faltan en el registro servidor .. %d" % missing_ticks)
		lines.append("  Líneas mal formadas ....................... %d" % malformed_lines)
		lines.append("Resultado: %s" % ("CORRECTO" if is_ok() else "DIFERENCIAS SIN EXPLICAR"))
		return "\n".join(lines)


	static func _ticks_text(ticks: Array[int], total: int) -> String:
		if ticks.is_empty():
			return ""
		var texts := PackedStringArray()
		for tick: int in ticks:
			texts.append(str(tick))
		var more: String = " ..." if total > ticks.size() else ""
		return "  (ticks %s%s)" % [", ".join(texts), more]


## Compara los registros de dos archivos. [param net_id] es el jugador del servidor que era ese bot
## (0 = lo deduce: el único jugador cuyo estado en el primer tick del bot es el estado propio de su
## primer snapshot).
static func compare_files(server_path: String, bot_path: String, net_id: int = 0) -> Result:
	var result := Result.new()
	for path: String in [server_path, bot_path]:
		if not FileAccess.file_exists(path):
			result.error = "no existe el archivo %s" % path
			return result
	var server_lines: PackedStringArray = FileAccess.get_file_as_string(server_path).split("\n")
	var bot_lines: PackedStringArray = FileAccess.get_file_as_string(bot_path).split("\n")
	return compare(server_lines, bot_lines, net_id)


## Compara las líneas de los dos registros (ver la documentación de la clase).
static func compare(server_lines: PackedStringArray, bot_lines: PackedStringArray,
		net_id: int = 0) -> Result:
	var result := Result.new()
	var bot: Array[PackedStringArray] = []
	for line: String in bot_lines:
		var text: String = line.strip_edges()
		if text.is_empty():
			continue
		var fields: PackedStringArray = text.split(",")
		if fields.size() != 3 or not fields[0].is_valid_int():
			result.malformed_lines += 1
			continue
		bot.append(fields)
	result.bot_lines = bot.size()
	if bot.is_empty():
		result.error = "el registro del bot no tiene ninguna línea"
		return result

	var chosen: int = net_id
	if chosen <= 0:
		chosen = _detect_net_id(server_lines, bot[0], result)
		if chosen <= 0:
			return result
	result.net_id = chosen

	# Estado y marca de sustitución del jugador por tick.
	var server_hex: Dictionary[int, String] = {}
	var substituted: Dictionary[int, bool] = {}
	var first_tick: int = -1
	for line: String in server_lines:
		var fields: PackedStringArray = line.strip_edges().split(",")
		if fields.size() != 4 or not fields[0].is_valid_int() or not fields[1].is_valid_int():
			if not line.strip_edges().is_empty():
				result.malformed_lines += 1
			continue
		if fields[1].to_int() != chosen:
			continue
		var tick: int = fields[0].to_int()
		server_hex[tick] = fields[3]
		substituted[tick] = fields[2] == "1"
		if first_tick < 0 or tick < first_tick:
			first_tick = tick
	if server_hex.is_empty():
		result.error = "el registro del servidor no tiene al jugador net_id %d" % chosen
		return result

	var previous_tick: int = first_tick - 1
	for fields: PackedStringArray in bot:
		var tick: int = fields[0].to_int()
		var predicted: String = fields[1]
		var from_server: String = fields[2]
		var window_start: int = previous_tick + 1
		previous_tick = tick
		if not server_hex.has(tick):
			result.missing_ticks += 1
			continue
		if server_hex[tick] != from_server:
			result.server_mismatches += 1
			continue
		if predicted.is_empty():
			result.unpredicted += 1
			_remember(result.unpredicted_ticks, tick)
		elif predicted == from_server:
			result.matches += 1
		elif _any_substitution(substituted, window_start, tick):
			result.explained += 1
			_remember(result.explained_ticks, tick)
		else:
			result.unexplained += 1
			_remember(result.unexplained_ticks, tick)
	return result


# Jugador del servidor que tiene, en el tick de la primera línea del bot, el estado que le llegó en
# ese snapshot. Si no hay uno solo, deja el motivo en result.error y devuelve 0.
static func _detect_net_id(server_lines: PackedStringArray, first_bot_line: PackedStringArray,
		result: Result) -> int:
	var tick: int = first_bot_line[0].to_int()
	var state: String = first_bot_line[2]
	var candidates: Array[int] = []
	for line: String in server_lines:
		var fields: PackedStringArray = line.strip_edges().split(",")
		if fields.size() == 4 and fields[0].is_valid_int() and fields[0].to_int() == tick \
				and fields[3] == state and fields[1].is_valid_int():
			candidates.append(fields[1].to_int())
	if candidates.size() == 1:
		return candidates[0]
	if candidates.is_empty():
		result.error = "ningún jugador del servidor tiene en el tick %d el estado del primer " \
				% tick + "snapshot del bot (indica el net_id)"
	else:
		result.error = "varios jugadores del servidor (%s) tienen ese estado en el tick %d " \
				% [", ".join(PackedStringArray(candidates.map(func(id: int) -> String: return str(id)))),
				tick] + "(indica el net_id)"
	return 0


# true si el servidor sustituyó alguna entrada del jugador en [from_tick, to_tick].
static func _any_substitution(substituted: Dictionary[int, bool], from_tick: int,
		to_tick: int) -> bool:
	for tick: int in range(from_tick, to_tick + 1):
		if substituted.get(tick, false):
			return true
	return false


static func _remember(list: Array[int], tick: int) -> void:
	if list.size() < MAX_LISTED_TICKS:
		list.append(tick)
