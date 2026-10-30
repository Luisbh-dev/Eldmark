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
## [code]{tick, players, p50_us, p99_us, max_us}[/code] en el orden del registro. Cada línea resume los últimos
## 2048 ticks (34 s) hasta su marca, así que la serie sirve para ver cómo evoluciona una batalla larga.
static func parse_tick_timeline(log_text: String) -> Array[Dictionary]:
	var regex := RegEx.new()
	regex.compile(TICK_LINE_PATTERN)
	var marks: Array[Dictionary] = []
	for line: String in log_text.split("\n"):
		var found: RegExMatch = regex.search(line)
		if found != null:
			marks.append({
				"tick": found.get_string(1).to_int(), "players": found.get_string(2).to_int(),
				"p50_us": found.get_string(3).to_int(), "p99_us": found.get_string(4).to_int(),
				"max_us": found.get_string(5).to_int(),
			})
	return marks


## Resume las marcas de [method parse_tick_timeline] entre [param first_tick] y [param last_tick] (ambos
## incluidos): [code]{marks, p50_us, p99_us, worst_p99_us, max_us}[/code] con el número de marcas, la mediana de
## sus p50 y de sus p99, el peor p99 y el mayor máximo. Vacío si no hay ninguna.
static func timeline_window(marks: Array[Dictionary], first_tick: int, last_tick: int) -> Dictionary:
	var p50s: Array[int] = []
	var p99s: Array[int] = []
	var worst_max: int = 0
	for mark: Dictionary in marks:
		var tick: int = int(mark["tick"])
		if tick < first_tick or tick > last_tick:
			continue
		p50s.append(int(mark["p50_us"]))
		p99s.append(int(mark["p99_us"]))
		worst_max = maxi(worst_max, int(mark["max_us"]))
	if p50s.is_empty():
		return {}
	p50s.sort()
	p99s.sort()
	return {
		"marks": p50s.size(), "p50_us": p50s[p50s.size() / 2], "p99_us": p99s[p99s.size() / 2],
		"worst_p99_us": p99s[p99s.size() - 1], "max_us": worst_max,
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


## Cifras de la fase 4 de una refriega (H5; docs/habilidades.md, secciones 7.3 y 8), del bloque
## [code]combat[/code] del informe del servidor ([method ZoneServer.write_report]): flechas (disparos, a quién dan,
## pico de vivas frente al tope de la zona, las que echó el tope, rebobinados rechazados, coste por tick ocupado y
## mensajes) y el resto del kit (efectos, curaciones, interrupciones y derribos). [param seconds]: lo que duró el
## servidor.
static func phase_4_figures(server: Dictionary, seconds: float) -> Dictionary:
	var combat: Dictionary = server.get("combat", {})
	var busy: int = int(combat.get("projectile_busy_ticks", 0))
	var fired: int = int(combat.get("projectiles_fired", 0))
	return {
		"fired": fired,
		"fired_per_s": float(fired) / seconds if seconds > 0.0 else 0.0,
		"harmless": int(combat.get("projectiles_harmless", 0)),
		"character_hits": int(combat.get("projectile_character_hits", 0)),
		"world_hits": int(combat.get("projectile_world_hits", 0)),
		"arrow_blocked": int(combat.get("arrow_blocked", 0)) + int(combat.get("wall_blocked", 0)),
		"expired": int(combat.get("projectiles_expired", 0)),
		"evicted": int(combat.get("projectiles_evicted", 0)),
		"peak": int(combat.get("projectile_peak", 0)),
		"zone_cap": CombatCatalog.rules().max_projectiles_per_zone,
		"rewind_rejected": int(combat.get("projectile_rewind_rejected", 0)),
		"busy_ticks": busy,
		"projectile_us_per_busy_tick": float(combat.get("projectile_us", 0)) / float(busy) if busy > 0 else 0.0,
		"segments": int(combat.get("projectile_segments", 0)),
		"capsule_tests": int(combat.get("projectile_capsule_tests", 0)),
		"messages": int(combat.get("projectile_messages_sent", 0)),
		"kb_per_s": float(combat.get("projectile_bytes_sent", 0)) / 1024.0 / seconds if seconds > 0.0 else 0.0,
		"status_applied": int(combat.get("status_applied", 0)),
		"pulses": int(combat.get("pulses", 0)),
		"healed": int(combat.get("healed", 0)),
		"interrupts": int(combat.get("interrupts", 0)),
		"downs": int(combat.get("downs", 0)),
		"revives": int(combat.get("revives", 0)),
		"executions": int(combat.get("executions", 0)),
		"bled_out": int(combat.get("bled_out", 0)),
	}
