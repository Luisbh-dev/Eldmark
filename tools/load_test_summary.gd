class_name LoadTestSummary
extends RefCounted
## Calculations of the [code]tools/load_test.gd[/code] summary that do not need to launch processes (and that
## are therefore tested in [code]tests/test_load_test.gd[/code]): the percentage of substituted inputs within
## the measurement window.
## [br][br]
## The server report gives the percentage for the [b]whole session[/b], with the startup included: while
## [TickSync] finds its lead each bot loses a few dozen inputs (more with 100 ms of RTT),
## and in 30 s that fixed cost weighs more than 1 %. The phase 2 criterion (docs/networking.md, 16) is measured
## in steady state, so what had accumulated when the window started is subtracted. The server only writes the report when
## it closes, but every 600 ticks it writes to its log a line
## "Métricas (tick N): … entradas sustituidas X %" (metrics, substituted inputs) with the accumulated percentage; since the inputs
## consumed up to tick N come from each player's join and leave ticks in the report, from them the substituted ones
## accumulated at each line are recovered.

## Metrics line of the server log: tick and accumulated percentage of substituted inputs.
const METRICS_LINE_PATTERN: String = "Métricas \\(tick (\\d+)\\):.*entradas sustituidas (\\d+(?:\\.\\d+)?) %"
## The same line, for the tick of each mark: players and p50, p99 and maximum of the tick (µs) over the last
## 2048 ticks (34 s) up to that mark.
const TICK_LINE_PATTERN: String = "Métricas \\(tick (\\d+)\\): (\\d+) jugadores, tick p50 (\\d+) µs / p99 (\\d+) µs / máx (\\d+) µs"
## At the end of the same line (since F6b, GUE-16): the NPCs the server simulates at that mark (the war ones and the
## dummies). Earlier lines do not carry it.
const NPC_COUNT_PATTERN: String = ", (\\d+) PNJ\\s*$"


## Accumulated percentage of substituted inputs of each metrics line in [param log_text]
## (the server log): [code]{tick: percentage}[/code].
static func parse_metrics_log(log_text: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile(METRICS_LINE_PATTERN)
	var result: Dictionary = {}
	for line: String in log_text.split("\n"):
		var found: RegExMatch = regex.search(line)
		if found != null:
			result[found.get_string(1).to_int()] = found.get_string(2).to_float()
	return result


## The server tick at each metrics line of [param log_text]: a list of
## [code]{tick, players, npcs, p50_us, p99_us, max_us}[/code] in log order ([code]npcs[/code], the NPCs that
## were being simulated at that mark; -1 if the line does not say). Each line summarises the last 2048 ticks (34 s) up to its
## mark, so the series is useful to see how a long battle evolves.
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


## Summarises the marks of [method parse_tick_timeline] between [param first_tick] and [param last_tick] (both
## inclusive): [code]{marks, p50_us, p99_us, worst_p99_us, max_us, npcs_min, npcs_max, players_min, players_max}[/code]
## with the number of marks, the median of their p50s and of their p99s, the worst p99, the largest maximum, the NPCs there were at
## minimum and at maximum in them (-1 if none says) and the same for the players (if they change within the window,
## the marks are not all from the same load). Empty if there are none.
static func timeline_window(marks: Array[Dictionary], first_tick: int, last_tick: int) -> Dictionary:
	var p50s: Array[int] = []
	var p99s: Array[int] = []
	var worst_max: int = 0
	var npcs_min: int = -1
	var npcs_max: int = -1
	var players_min: int = -1
	var players_max: int = -1
	for mark: Dictionary in marks:
		var tick: int = int(mark["tick"])
		if tick < first_tick or tick > last_tick:
			continue
		p50s.append(int(mark["p50_us"]))
		p99s.append(int(mark["p99_us"]))
		worst_max = maxi(worst_max, int(mark["max_us"]))
		var players: int = int(mark.get("players", -1))
		if players >= 0:
			players_min = players if players_min < 0 else mini(players_min, players)
			players_max = maxi(players_max, players)
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
		"players_min": players_min, "players_max": players_max,
	}


## How many players (people and fakes) were on the server at each tick from [param first_tick] to [param last_tick]
## (both inclusive), according to the join and leave of each entry of the report's [code]player_list[/code] ([param players]):
## present from its [code]joined_tick[/code] to the tick before its [code]left_tick[/code] (-1, or
## [param end_tick] or more, the server close: until the end). Returns [code]{min, max, ticks, ticks_at_max}[/code]:
## the lowest and highest number, the ticks in the range and how many of them had the highest. Useful to know whether the
## percentiles of the server report (from its last 2048 ticks) are from the load that was meant to be measured: with many
## players the server runs slower than real time, and a swarm that closes by its clock used to leave before
## that stretch ended (GUE-16, F6b review). Empty if the range is empty.
static func presence(players: Array, first_tick: int, last_tick: int, end_tick: int) -> Dictionary:
	if last_tick < first_tick:
		return {}
	var changes: Dictionary = {}
	var current: int = 0
	for entry: Dictionary in players:
		var joined: int = int(entry.get("joined_tick", 0))
		var left: int = int(entry.get("left_tick", -1))
		if left < 0 or left >= end_tick:
			left = last_tick + 1
		if left <= first_tick or joined > last_tick or left <= joined:
			continue
		if joined <= first_tick:
			current += 1
		else:
			changes[joined] = int(changes.get(joined, 0)) + 1
		if left <= last_tick:
			changes[left] = int(changes.get(left, 0)) - 1
	var ticks: Array = changes.keys()
	ticks.sort()
	# Spans [from, to) with the same number of players.
	var spans: Array[Vector3i] = []
	var start: int = first_tick
	for tick: int in ticks:
		spans.append(Vector3i(start, tick, current))
		current += int(changes[tick])
		start = tick
	spans.append(Vector3i(start, last_tick + 1, current))
	var lowest: int = 0x7FFFFFFF
	var highest: int = -1
	for span: Vector3i in spans:
		if span.y > span.x:
			lowest = mini(lowest, span.z)
			highest = maxi(highest, span.z)
	var at_max: int = 0
	for span: Vector3i in spans:
		if span.z == highest:
			at_max += span.y - span.x
	return {"min": lowest, "max": highest, "ticks": last_tick - first_tick + 1, "ticks_at_max": at_max}


## Inputs the server had consumed from the network players (not the fakes) up to tick
## [param tick]: a player consumes one per tick from its join ([code]joined_tick[/code]) until its leave
## ([code]left_tick[/code]; -1 = still in, and then until [param end_tick], the server's last
## tick). [param players] is the server report's [code]player_list[/code].
static func consumed_until(players: Array, tick: int, end_tick: int) -> int:
	var total: int = 0
	for entry: Dictionary in players:
		if bool(entry.get("fake", false)):
			continue
		var left: int = int(entry.get("left_tick", -1))
		var until: int = mini(tick, end_tick if left < 0 else left)
		total += maxi(until - int(entry.get("joined_tick", 0)), 0)
	return total


## Substituted inputs within the measurement window, from the first metrics line from
## [param first_tick] to the last one up to [param last_tick]: [code]{from_tick, to_tick, inputs,
## substituted, percent}[/code], with the inputs consumed and substituted in the window and the
## percentage. Empty if there are not two lines in that range or no network player consumed anything.
## [param cumulative] is [method parse_metrics_log], [param players] the report's [code]player_list[/code]
## and [param end_tick] the server's last tick.
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


## Combat figures of a brawl from the server report ([param server], from
## [method ZoneServer.write_report]) and the [param seconds] the run lasted:
## [code]{hits, blocked, deaths, events, events_sent, event_kb_per_s, hit_tests, resolve_us_per_test,
## resolve_share, events_us_per_event}[/code].
## [br]- [code]events_sent[/code] counts packets (an event reaches everyone who has the attacker or the victim
## as relevant) and [code]event_kb_per_s[/code] comes from [code]event_bytes_sent[/code] (without
## ENet headers) divided by the seconds of the run.
## [br]- [code]resolve_us_per_test[/code]: µs spent resolving hits with rewind in the ticks in which
## there was something to test ([code]resolve_us[/code]) per shape and line-of-sight check
## ([code]hit_tests[/code]); 0 if there were none. [code]resolve_busy_ticks[/code] are those ticks.
## [br]- [code]resolve_share[/code]: fraction of the [code]combat[/code] section taken up by the
## [code]combat_resolve[/code] section (all ticks).
## [br]- [code]events_us_per_event[/code]: average µs of [code]combat_events[/code] per emitted event.
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


## When the real bots of a siege reached the fort (GUE-16; since GUE-44 those that join when the fakes have already
## left wait for their own in the camp): from the swarm reports ([param swarms], one per process, with
## the [code]clients[/code] list of [method SwarmBot.get_stats]), the siege bots there are
## ([code]bots[/code]), how many have ever got within [constant BotBrain.SIEGE_RALLY_FORT_RADIUS] of the
## circle ([code]arrived[/code]), how many did so up to and including tick [param first_tick], the start of the
## measurement window ([code]before_window[/code]), and the server tick of the last to arrive ([code]last_tick[/code];
## -1 if none arrived). Bots without [code]fort_reached_tick[/code] (not siege ones) do not count.
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


## Phase 4 figures of a brawl (H5; docs/abilities.md, sections 7.3 and 8), from the
## [code]combat[/code] block of the server report ([method ZoneServer.write_report]): arrows (shots, who they hit,
## peak of live ones against the zone cap, those evicted by the cap, rewinds rejected, cost per busy tick and
## messages) and the rest of the kit (effects, heals, interrupts and knockdowns). [param seconds]: how long the
## server ran.
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


# --- Soak (tools/load_test.gd --soak) -------------------------------------------------------------

## Seconds at the start of a soak that are not judged (the zone and the caches warm up).
const SOAK_WARMUP_SECONDS: float = 600.0
## Maximum growth of static memory and of the object count after the warm-up, in percent.
const SOAK_MAX_GROWTH_PERCENT: float = 10.0
## Maximum drift of the tick p99 between the start and the end of the judged part, in percent.
const SOAK_MAX_P99_DRIFT_PERCENT: float = 10.0
## Samples averaged at each end of the judged part, so that one odd sample does not decide.
const SOAK_EDGE_SAMPLES: int = 6


## A sample of the soak out of the server's report (a [method ZoneServer.write_report] dictionary) at second [param t].
static func soak_sample(report: Dictionary, t: float) -> Dictionary:
	var metrics: Dictionary = report.get("metrics", {})
	var tick: Dictionary = (metrics.get("sections", {}) as Dictionary).get("tick", {})
	var process: Dictionary = metrics.get("process", {})
	var players: Dictionary = report.get("players", {})
	var strikes: Dictionary = report.get("strikes", {})
	return {
		"t": t,
		"tick": int(report.get("ticks", 0)),
		"p50_us": int(tick.get("p50", 0)),
		"p99_us": int(tick.get("p99", 0)),
		"max_us": int(tick.get("max", 0)),
		"static_memory": int(process.get("static_memory", 0)),
		"object_count": int(process.get("object_count", 0)),
		"node_count": int(process.get("node_count", 0)),
		"orphan_node_count": int(process.get("orphan_node_count", 0)),
		"players": int(players.get("current", 0)),
		"joined_total": int(players.get("joined_total", 0)),
		"left_total": int(players.get("left_total", 0)),
		"kicks": int(strikes.get("kicks_total", 0)),
		"physics_errors": int(report.get("physics_errors", 0)),
	}


## Judges a soak: [param series] is a list of [method soak_sample]. After [constant SOAK_WARMUP_SECONDS], the growth of
## static memory and of the object count (from the average of the first samples to that of the last ones) must stay
## below [constant SOAK_MAX_GROWTH_PERCENT], the drift of the tick p99 below [constant SOAK_MAX_P99_DRIFT_PERCENT],
## and there must be no kicks and no physics errors. [code]problems[/code] says what failed.
static func soak_figures(series: Array, warmup_seconds: float = SOAK_WARMUP_SECONDS) -> Dictionary:
	var judged: Array[Dictionary] = []
	for sample: Dictionary in series:
		if float(sample["t"]) >= warmup_seconds:
			judged.append(sample)
	var figures: Dictionary = {"samples": series.size(), "judged_samples": judged.size(), "problems": PackedStringArray()}
	var problems: PackedStringArray = figures["problems"]
	if judged.size() < 2 * SOAK_EDGE_SAMPLES:
		problems.append("too few samples after the warm-up (%d)" % judged.size())
		figures["criterion_met"] = false
		return figures
	var edge: int = mini(SOAK_EDGE_SAMPLES, judged.size() / 2)
	var first: Array = judged.slice(0, edge)
	var last: Array = judged.slice(judged.size() - edge)
	for key: String in ["static_memory", "object_count", "node_count"]:
		var before: float = _average(first, key)
		var after: float = _average(last, key)
		var growth: float = 100.0 * (after - before) / before if before > 0.0 else 0.0
		figures["%s_growth_percent" % key] = growth
		if key != "node_count" and growth > SOAK_MAX_GROWTH_PERCENT:
			problems.append("%s grew %.1f %% (limit %.0f %%)" % [key, growth, SOAK_MAX_GROWTH_PERCENT])
	var p99_before: float = _average(first, "p99_us")
	var p99_after: float = _average(last, "p99_us")
	var drift: float = 100.0 * (p99_after - p99_before) / p99_before if p99_before > 0.0 else 0.0
	figures["p99_before_us"] = p99_before
	figures["p99_after_us"] = p99_after
	figures["p99_drift_percent"] = drift
	if drift > SOAK_MAX_P99_DRIFT_PERCENT:
		problems.append("the tick p99 drifted %.1f %% (limit %.0f %%)" % [drift, SOAK_MAX_P99_DRIFT_PERCENT])
	var kicks: int = int((series[series.size() - 1] as Dictionary)["kicks"])
	var physics_errors: int = int((series[series.size() - 1] as Dictionary)["physics_errors"])
	figures["kicks"] = kicks
	figures["physics_errors"] = physics_errors
	if kicks > 0:
		problems.append("%d kicks" % kicks)
	if physics_errors > 0:
		problems.append("%d physics errors" % physics_errors)
	figures["criterion_met"] = problems.is_empty()
	return figures


static func _average(samples: Array, key: String) -> float:
	var total: float = 0.0
	for sample: Dictionary in samples:
		total += float(sample[key])
	return total / float(maxi(samples.size(), 1))
