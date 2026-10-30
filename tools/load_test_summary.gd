class_name LoadTestSummary
extends RefCounted
## Cálculos del resumen de [code]tools/load_test.gd[/code] que no necesitan lanzar procesos (y que por
## eso se prueban en [code]tests/test_load_test.gd[/code]): el porcentaje de entradas sustituidas dentro
## de la ventana de medida.
## [br][br]
## El informe del servidor da el porcentaje de [b]toda la sesión[/b], con el arranque dentro: mientras
## [TickSync] encuentra su antelación cada bot pierde unas decenas de entradas (más con 100 ms de RTT),
## y en 30 s ese coste fijo pesa más de un 1 %. El criterio de la fase 2 (docs/red.md, 16) se mide en
## régimen, así que se resta lo acumulado al empezar la ventana. El servidor solo escribe el informe al
## cerrar, pero cada 600 ticks escribe en su registro una línea
## «Métricas (tick N): … entradas sustituidas X %» con el porcentaje acumulado; como las entradas
## consumidas hasta el tick N salen de los ticks de alta y baja de cada jugador del informe, de ahí se
## recuperan las sustituidas acumuladas en cada línea.

## Línea de métricas del registro del servidor: tick y porcentaje acumulado de sustituidas.
const METRICS_LINE_PATTERN: String = "Métricas \\(tick (\\d+)\\):.*entradas sustituidas (\\d+(?:\\.\\d+)?) %"
## La misma línea, para el tick de cada marca: jugadores y p50, p99 y máximo del tick (µs) de los últimos
## 2048 ticks (34 s) hasta esa marca.
const TICK_LINE_PATTERN: String = "Métricas \\(tick (\\d+)\\): (\\d+) jugadores, tick p50 (\\d+) µs / p99 (\\d+) µs / máx (\\d+) µs"
## Al final de la misma línea (desde F6b, GUE-16): los PNJ que simula el servidor en esa marca (los de guerra y los
## maniquíes). Las líneas de antes no lo llevan.
const NPC_COUNT_PATTERN: String = ", (\\d+) PNJ\\s*$"


## Porcentaje acumulado de entradas sustituidas de cada línea de métricas de [param log_text]
## (el registro del servidor): [code]{tick: porcentaje}[/code].
static func parse_metrics_log(log_text: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile(METRICS_LINE_PATTERN)
	var result: Dictionary = {}
	for line: String in log_text.split("\n"):
		var found: RegExMatch = regex.search(line)
		if found != null:
			result[found.get_string(1).to_int()] = found.get_string(2).to_float()
	return result


## El tick del servidor en cada línea de métricas de [param log_text]: una lista de
## [code]{tick, players, npcs, p50_us, p99_us, max_us}[/code] en el orden del registro ([code]npcs[/code], los PNJ que
## se simulaban en esa marca; -1 si la línea no lo dice). Cada línea resume los últimos 2048 ticks (34 s) hasta su
## marca, así que la serie sirve para ver cómo evoluciona una batalla larga.
static func parse_tick_timeline(log_text: String) -> Array[Dictionary]:
	var regex := RegEx.new()
	regex.compile(TICK_LINE_PATTERN)
	var npc_regex := RegEx.new()
	npc_regex.compile(NPC_COUNT_PATTERN)
	var marks: Array[Dictionary] = []
	for line: String in log_text.split("\n"):
		var found: RegExMatch = regex.search(line)
		if found != null:
			var npcs: RegExMatch = npc_regex.search(line)
			marks.append({
				"tick": found.get_string(1).to_int(), "players": found.get_string(2).to_int(),
				"npcs": npcs.get_string(1).to_int() if npcs != null else -1,
				"p50_us": found.get_string(3).to_int(), "p99_us": found.get_string(4).to_int(),
				"max_us": found.get_string(5).to_int(),
			})
	return marks


## Resume las marcas de [method parse_tick_timeline] entre [param first_tick] y [param last_tick] (ambos
## incluidos): [code]{marks, p50_us, p99_us, worst_p99_us, max_us, npcs_min, npcs_max}[/code] con el número de
## marcas, la mediana de sus p50 y de sus p99, el peor p99, el mayor máximo y los PNJ que había como mínimo y como
## máximo en ellas (-1 si ninguna lo dice). Vacío si no hay ninguna.
static func timeline_window(marks: Array[Dictionary], first_tick: int, last_tick: int) -> Dictionary:
	var p50s: Array[int] = []
	var p99s: Array[int] = []
	var worst_max: int = 0
	var npcs_min: int = -1
	var npcs_max: int = -1
	for mark: Dictionary in marks:
		var tick: int = int(mark["tick"])
		if tick < first_tick or tick > last_tick:
			continue
		p50s.append(int(mark["p50_us"]))
		p99s.append(int(mark["p99_us"]))
		worst_max = maxi(worst_max, int(mark["max_us"]))
		var npcs: int = int(mark.get("npcs", -1))
		if npcs >= 0:
			npcs_min = npcs if npcs_min < 0 else mini(npcs_min, npcs)
			npcs_max = maxi(npcs_max, npcs)
	if p50s.is_empty():
		return {}
	p50s.sort()
	p99s.sort()
	return {
		"marks": p50s.size(), "p50_us": p50s[p50s.size() / 2], "p99_us": p99s[p99s.size() / 2],
		"worst_p99_us": p99s[p99s.size() - 1], "max_us": worst_max, "npcs_min": npcs_min, "npcs_max": npcs_max,
	}


## Entradas que el servidor había consumido de los jugadores de red (no los falsos) hasta el tick
## [param tick]: un jugador consume una por tick desde su alta ([code]joined_tick[/code]) hasta su baja
## ([code]left_tick[/code]; -1 = sigue dentro, y entonces hasta [param end_tick], el último tick del
## servidor). [param players] es el [code]player_list[/code] del informe del servidor.
static func consumed_until(players: Array, tick: int, end_tick: int) -> int:
	var total: int = 0
	for entry: Dictionary in players:
		if bool(entry.get("fake", false)):
			continue
		var left: int = int(entry.get("left_tick", -1))
		var until: int = mini(tick, end_tick if left < 0 else left)
		total += maxi(until - int(entry.get("joined_tick", 0)), 0)
	return total


## Entradas sustituidas dentro de la ventana de medida, de la primera línea de métricas desde
## [param first_tick] a la última hasta [param last_tick]: [code]{from_tick, to_tick, inputs,
## substituted, percent}[/code], con las entradas consumidas y sustituidas en la ventana y el
## porcentaje. Vacío si no hay dos líneas en ese rango o ningún jugador de red consumió nada.
## [param cumulative] es [method parse_metrics_log], [param players] el [code]player_list[/code] del
## informe y [param end_tick] el último tick del servidor.
static func window_substituted(cumulative: Dictionary, players: Array, first_tick: int, last_tick: int,
		end_tick: int) -> Dictionary:
	var from_tick: int = -1
	var to_tick: int = -1
	for tick: int in cumulative:
		if tick >= first_tick and (from_tick < 0 or tick < from_tick):
			from_tick = tick
		if tick <= last_tick and tick > to_tick:
			to_tick = tick
	if from_tick < 0 or to_tick <= from_tick:
		return {}
	var consumed_from: int = consumed_until(players, from_tick, end_tick)
	var consumed_to: int = consumed_until(players, to_tick, end_tick)
	if consumed_to <= consumed_from:
		return {}
	var substituted_from: int = roundi(float(cumulative[from_tick]) / 100.0 * consumed_from)
	var substituted_to: int = roundi(float(cumulative[to_tick]) / 100.0 * consumed_to)
	var inputs: int = consumed_to - consumed_from
	var substituted: int = maxi(substituted_to - substituted_from, 0)
	return {
		"from_tick": from_tick,
		"to_tick": to_tick,
		"inputs": inputs,
		"substituted": substituted,
		"percent": 100.0 * float(substituted) / float(inputs),
	}


## Cifras del combate de una refriega a partir del informe del servidor ([param server], de
## [method ZoneServer.write_report]) y de los [param seconds] que duró la ejecución:
## [code]{hits, blocked, deaths, events, events_sent, event_kb_per_s, hit_tests, resolve_us_per_test,
## resolve_share, events_us_per_event}[/code].
## [br]- [code]events_sent[/code] cuenta paquetes (un evento llega a todos los que tienen relevante al
## atacante o a la víctima) y [code]event_kb_per_s[/code] sale de [code]event_bytes_sent[/code] (sin
## cabeceras de ENet) entre los segundos de la ejecución.
## [br]- [code]resolve_us_per_test[/code]: µs de resolver los golpes con rebobinado en los ticks en que
## había algo que probar ([code]resolve_us[/code]) por comprobación de forma y línea de visión
## ([code]hit_tests[/code]); 0 si no hubo. [code]resolve_busy_ticks[/code] son esos ticks.
## [br]- [code]resolve_share[/code]: fracción de la sección [code]combat[/code] que ocupa la sección
## [code]combat_resolve[/code] (todos los ticks).
## [br]- [code]events_us_per_event[/code]: µs medios de [code]combat_events[/code] por evento emitido.
static func combat_figures(server: Dictionary, seconds: float) -> Dictionary:
	var combat: Dictionary = server.get("combat", {})
	var sections: Dictionary = (server.get("metrics", {}) as Dictionary).get("sections", {})
	var resolve_total: float = float((sections.get("combat_resolve", {}) as Dictionary).get("total_us", 0))
	var combat_total: float = float((sections.get("combat", {}) as Dictionary).get("total_us", 0))
	var events_total: float = float((sections.get("combat_events", {}) as Dictionary).get("total_us", 0))
	var hit_tests: int = int(combat.get("hit_tests", 0))
	var events: int = int(combat.get("events", 0))
	return {
		"hits": int(combat.get("hits", 0)),
		"blocked": int(combat.get("blocked", 0)),
		"deaths": int(combat.get("deaths", 0)),
		"events": events,
		"events_sent": int(combat.get("events_sent", 0)),
		"event_kb_per_s": float(combat.get("event_bytes_sent", 0)) / 1024.0 / seconds \
				if seconds > 0.0 else 0.0,
		"hit_tests": hit_tests,
		"resolve_busy_ticks": int(combat.get("resolve_busy_ticks", 0)),
		"resolve_us_per_test": float(combat.get("resolve_us", 0)) / float(hit_tests) \
				if hit_tests > 0 else 0.0,
		"resolve_share": resolve_total / combat_total if combat_total > 0.0 else 0.0,
		"events_us_per_event": events_total / float(events) if events > 0 else 0.0,
	}


## Cuándo llegaron al fuerte los bots reales de un asedio (GUE-16; desde GUE-44 los que entran cuando los falsos ya han
## salido esperan a los suyos en el campamento): de los informes de los enjambres ([param swarms], uno por proceso, con
## la lista [code]clients[/code] de [method SwarmBot.get_stats]), los bots de asedio que hay
## ([code]bots[/code]), cuántos han llegado alguna vez a menos de [constant BotBrain.SIEGE_RALLY_FORT_RADIUS] del
## círculo ([code]arrived[/code]), cuántos lo hicieron hasta el tick [param first_tick] incluido, el principio de la
## ventana de medida ([code]before_window[/code]), y el tick del servidor del último en llegar ([code]last_tick[/code];
## -1 si no llegó ninguno). Los bots sin [code]fort_reached_tick[/code] (no son de asedio) no cuentan.
static func fort_arrivals(swarms: Array, first_tick: int) -> Dictionary:
	var bots: int = 0
	var arrived: int = 0
	var before_window: int = 0
	var last_tick: int = -1
	for data: Dictionary in swarms:
		for client: Dictionary in data.get("clients", []):
			if not client.has("fort_reached_tick"):
				continue
			bots += 1
			var reached: int = int(client["fort_reached_tick"])
			if reached < 0:
				continue
			arrived += 1
			last_tick = maxi(last_tick, reached)
			if reached <= first_tick:
				before_window += 1
	return {"bots": bots, "arrived": arrived, "before_window": before_window, "last_tick": last_tick}
