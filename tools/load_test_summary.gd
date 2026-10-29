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
