class_name BattleSummary
extends RefCounted
## Summary of a battle log ([BattleLog], GUE-17): what whoever tunes the fort looks at without touching code. Used by
## [code]tools/war/summarize_battle.gd[/code].
## [br][br]
## It extracts from the JSON Lines:
## [br]- [b]Captures[/b]: for each captured fort, the seconds from the start of the cycle (the start of the battle or the
## last reset) to the capture, since the captain fell, and the duration of the capture itself (since "capture started").
## [br]- [b]Gate[/b]: the seconds between the first hit on the gate and its breaking.
## [br]- [b]Deaths by route[/b]: where players have fallen, classified by position as [code]walkway[/code] (the fort's
## walkway and the top of its ramps: at [constant WALKWAY_MIN_HEIGHT] m or more above the circle and less than
## [constant WALKWAY_RADIUS] from it, or, if the routes know the walkway, on its axis; GUE-45), [code]gate[/code] (the
## esplanade in front of the gate and the courtyard: less than [constant GATE_RADIUS] from the circle; that is where both
## routes end up, so without this class all assault deaths would come out as "ford"), [code]bridge[/code] or
## [code]ford[/code] by the path; [code]other[/code] if they are not near any route of [ApproachRoutes].
## [br]- NPC deaths, by place with the same classes (the Hollow and the garrison patrol the walkway).
## [br]- The counts of war notices and of deaths per realm.

## Key for deaths on the fort's walkway and at no known place.
const WALKWAY: StringName = &"walkway"
const GATE: StringName = &"gate"
const OTHER: StringName = &"other"
## Up to what distance (m) from a route a death counts as its own.
const ROUTE_MAX_DISTANCE: float = 30.0
## Radius (m) around the circle within which a death counts as belonging to the gate and the courtyard (the esplanade,
## the gate and the enclosure), instead of a route's.
const GATE_RADIUS: float = 25.0
## Radius (m) around the circle within which a high death counts as belonging to the walkway and how far above the
## circle's ground (m) it must be.
const WALKWAY_RADIUS: float = 30.0
const WALKWAY_MIN_HEIGHT: float = 2.0
## With routes that know the walkway ([method ApproachRoutes.has_walkway]): a death less than this (m) from its axis
## horizontally and no more than [constant WALKWAY_LEVEL_MARGIN] below its floor belongs to the walkway, also far from
## the circle (its back corners).
const WALKWAY_BAND: float = 1.5
const WALKWAY_LEVEL_MARGIN: float = 1.0
## Ticks per second of the data.
const TICK_RATE: int = 60


## Summarizes the log [param text] (the contents of the JSON Lines file). [param routes] are the zone's routes (null =
## deaths are classified only as walkway or other). Lines that are not JSON are counted in [code]bad_lines[/code]. Result
## keys:
## [codeblock]
## zone, ticks, duration_s, bad_lines
## war_events    {notice key: times}
## captures      [{fortress, realm, ticks_from_cycle_start, seconds_from_cycle_start,
##                 seconds_from_captain_down, seconds_capturing}]
## gate_breaks   [{fortress, seconds}]
## deaths        {players, npcs, by_route {route: dead players}, by_realm {realm: dead players},
##                npcs_by_route {route: dead NPCs}}
## [/codeblock]
static func summarize(text: String, routes: ApproachRoutes = null) -> Dictionary:
	var result: Dictionary = {
		"zone": "", "ticks": 0, "duration_s": 0.0, "bad_lines": 0, "war_events": {},
		"captures": [], "gate_breaks": [],
		"deaths": {"players": 0, "npcs": 0, "by_route": {}, "by_realm": {}, "npcs_by_route": {}},
	}
	var fortresses: Dictionary = {}
	# State per fortress: start tick of the cycle, of the captain's fall, of "capture started" and of the first hit on the
	# gate.
	var cycles: Dictionary = {}
	var json := JSON.new()
	for line: String in text.split("\n", false):
		# JSON.parse() returns the error without logging it (parse_string writes it to the log).
		if json.parse(line) != OK or not (json.data is Dictionary):
			result["bad_lines"] = int(result["bad_lines"]) + 1
			continue
		var entry: Dictionary = json.data
		var tick: int = int(entry.get("tick", 0))
		result["ticks"] = maxi(int(result["ticks"]), tick)
		match String(entry.get("event", "")):
			"battle_start":
				result["zone"] = String(entry.get("zone", ""))
				for fortress: Variant in entry.get("fortresses", []):
					if fortress is Dictionary:
						fortresses[String((fortress as Dictionary).get("id", ""))] = fortress
			"gate_damage_started":
				_cycle(cycles, String(entry.get("fortress", "")))["gate_start"] = tick
			"war":
				_note_war(result, cycles, entry, tick)
			"death":
				_note_death(result, entry, fortresses, routes)
	result["duration_s"] = float(int(result["ticks"])) / float(TICK_RATE)
	return result


## Classifies a death at position [param position] (x, y, z) as [code]walkway[/code], [code]bridge[/code],
## [code]ford[/code] or [code]other[/code]. [param fortress] is the log's fortress (with [code]circle[/code] and
## [code]position[/code]) or an empty dictionary; [param routes] the zone's routes or null.
static func classify_route(position: Array, fortress: Dictionary, routes: ApproachRoutes) -> StringName:
	if position.size() < 3:
		return OTHER
	var point := Vector2(float(position[0]), float(position[2]))
	var height: float = float(position[1])
	if routes != null and routes.has_walkway() and height >= routes.walkway_height - WALKWAY_LEVEL_MARGIN \
			and routes.walkway_distance(point) <= WALKWAY_BAND:
		return WALKWAY
	var circle: Array = fortress.get("circle", [])
	if circle.size() >= 3:
		var center := Vector2(float(circle[0]), float(circle[2]))
		if point.distance_to(center) <= WALKWAY_RADIUS and height >= float(circle[1]) + WALKWAY_MIN_HEIGHT:
			return WALKWAY
		if point.distance_to(center) <= GATE_RADIUS:
			return GATE
	if routes == null:
		return OTHER
	var best: StringName = OTHER
	var best_distance: float = ROUTE_MAX_DISTANCE
	for route: StringName in routes.get_route_ids():
		for realm: StringName in RealmCatalog.REALM_IDS:
			var distance: float = _distance_to_polyline(point, routes.get_points(route, realm))
			if distance < best_distance:
				best_distance = distance
				best = route
	return best


## The summary [param summary] ([method summarize]) as text in Spanish, for the terminal.
static func format(summary: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("Registro de batalla de «%s»: %d ticks (%.1f s)" % [summary["zone"],
			summary["ticks"], summary["duration_s"]])
	if int(summary["bad_lines"]) > 0:
		lines.append("  líneas ilegibles: %d" % int(summary["bad_lines"]))
	var captures: Array = summary["captures"]
	lines.append("Capturas: %d" % captures.size())
	for capture: Dictionary in captures:
		lines.append("  %s capturada por %s a los %.1f s del ciclo (%.1f s desde la caída del capitán, "
				% [capture["fortress"], WarEvents.realm_label(int(capture["realm"])),
				capture["seconds_from_cycle_start"], capture["seconds_from_captain_down"]]
				+ "%.1f s capturando)" % capture["seconds_capturing"])
	var breaks: Array = summary["gate_breaks"]
	lines.append("Puertas rotas: %d" % breaks.size())
	for gate_break: Dictionary in breaks:
		lines.append("  %s: %.1f s desde el primer golpe hasta romperla" % [gate_break["fortress"],
				gate_break["seconds"]])
	var deaths: Dictionary = summary["deaths"]
	lines.append("Muertes: %d de jugadores y %d de PNJ" % [deaths["players"], deaths["npcs"]])
	var labels: Dictionary = {"bridge": "puente", "ford": "vado", "gate": "explanada y patio", "walkway": "pasarela",
			"other": "otros sitios"}
	var by_route: Dictionary = deaths["by_route"]
	for route: String in ["bridge", "ford", "gate", "walkway", "other"]:
		lines.append("  %s: %d" % [labels[route], int(by_route.get(route, 0))])
	var npcs_by_route: Dictionary = deaths.get("npcs_by_route", {})
	if not npcs_by_route.is_empty():
		var npc_parts := PackedStringArray()
		for route: String in ["bridge", "ford", "gate", "walkway", "other"]:
			if npcs_by_route.has(route):
				npc_parts.append("%s %d" % [labels[route], int(npcs_by_route[route])])
		lines.append("  PNJ: %s" % ", ".join(npc_parts))
	var war_events: Dictionary = summary["war_events"]
	var names := PackedStringArray()
	for key: String in war_events:
		names.append("%s %d" % [key, int(war_events[key])])
	names.sort()
	lines.append("Avisos de guerra: %s" % (", ".join(names) if not names.is_empty() else "ninguno"))
	return "\n".join(lines)


# State of a fortress's cycle (created when it is named).
static func _cycle(cycles: Dictionary, fortress_id: String) -> Dictionary:
	if not cycles.has(fortress_id):
		cycles[fortress_id] = {"start": 0, "captain_down": -1, "capture_started": -1, "gate_start": -1}
	return cycles[fortress_id]


static func _note_war(result: Dictionary, cycles: Dictionary, entry: Dictionary, tick: int) -> void:
	var key: String = String(entry.get("war", ""))
	var events: Dictionary = result["war_events"]
	events[key] = int(events.get(key, 0)) + 1
	var fortress_id: String = String(entry.get("fortress", ""))
	var cycle: Dictionary = _cycle(cycles, fortress_id)
	match key:
		"captain_down":
			cycle["captain_down"] = tick
		"capture_started":
			cycle["capture_started"] = tick
		"gate_broken":
			if int(cycle["gate_start"]) >= 0:
				(result["gate_breaks"] as Array).append({"fortress": fortress_id,
						"seconds": float(tick - int(cycle["gate_start"])) / float(TICK_RATE)})
			cycle["gate_start"] = -1
		"fort_captured":
			var captain_down: int = int(cycle["captain_down"])
			var started: int = int(cycle["capture_started"])
			(result["captures"] as Array).append({
				"fortress": fortress_id, "realm": int(entry.get("realm", 0)),
				"ticks_from_cycle_start": tick - int(cycle["start"]),
				"seconds_from_cycle_start": float(tick - int(cycle["start"])) / float(TICK_RATE),
				"seconds_from_captain_down": float(tick - captain_down) / float(TICK_RATE) \
						if captain_down >= 0 else -1.0,
				"seconds_capturing": float(tick - started) / float(TICK_RATE) if started >= 0 else -1.0,
			})
			cycle["captain_down"] = -1
			cycle["capture_started"] = -1
			cycle["gate_start"] = -1
			cycle["start"] = tick
		"fort_reset":
			cycle["start"] = tick
			cycle["captain_down"] = -1
			cycle["capture_started"] = -1
			cycle["gate_start"] = -1


static func _note_death(result: Dictionary, entry: Dictionary, fortresses: Dictionary,
		routes: ApproachRoutes) -> void:
	var deaths: Dictionary = result["deaths"]
	var fortress: Dictionary = {}
	if not fortresses.is_empty():
		fortress = fortresses[fortresses.keys()[0]]
	var route: StringName = classify_route(entry.get("position", []), fortress, routes)
	if String(entry.get("victim_kind", "player")) != "player":
		deaths["npcs"] = int(deaths["npcs"]) + 1
		var npcs_by_route: Dictionary = deaths["npcs_by_route"]
		npcs_by_route[String(route)] = int(npcs_by_route.get(String(route), 0)) + 1
		return
	deaths["players"] = int(deaths["players"]) + 1
	var by_realm: Dictionary = deaths["by_realm"]
	var realm_key: String = str(int(entry.get("victim_realm", 0)))
	by_realm[realm_key] = int(by_realm.get(realm_key, 0)) + 1
	var by_route: Dictionary = deaths["by_route"]
	by_route[String(route)] = int(by_route.get(String(route), 0)) + 1


# Distance (m) in the plane from [param point] to the polyline [param polyline] (x, z points).
static func _distance_to_polyline(point: Vector2, polyline: PackedVector2Array) -> float:
	if polyline.is_empty():
		return INF
	if polyline.size() == 1:
		return point.distance_to(polyline[0])
	var best: float = INF
	for i: int in range(1, polyline.size()):
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, polyline[i - 1],
				polyline[i])
		best = minf(best, point.distance_to(closest))
	return best
