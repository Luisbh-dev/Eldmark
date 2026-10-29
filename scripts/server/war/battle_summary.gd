class_name BattleSummary
extends RefCounted
## Resumen de un registro de batalla ([BattleLog], GUE-17): lo que mira quien ajusta el fuerte sin
## tocar código. Lo usa [code]tools/war/summarize_battle.gd[/code].
## [br][br]
## Saca del JSON Lines:
## [br]- [b]Capturas[/b]: por cada fuerte capturado, los segundos desde el principio del ciclo (el inicio
## de la batalla o el último reinicio) hasta la captura, desde que cayó el capitán, y la duración de la
## propia captura (desde «captura iniciada»).
## [br]- [b]Puerta[/b]: los segundos entre el primer golpe a la puerta y su rotura.
## [br]- [b]Muertes por ruta[/b]: dónde han caído los jugadores, clasificados por posición como
## [code]bridge[/code] (puente), [code]ford[/code] (vado) o [code]walkway[/code] (pasarela del fuerte,
## alta y dentro de su recinto); [code]other[/code] si no están cerca de ninguna ruta de
## [ApproachRoutes].
## [br]- Los recuentos de avisos de guerra y de muertes por reino.

## Clave de las muertes en la pasarela del fuerte y en ningún sitio conocido.
const WALKWAY: StringName = &"walkway"
const OTHER: StringName = &"other"
## Hasta qué distancia (m) de una ruta cuenta una muerte como suya.
const ROUTE_MAX_DISTANCE: float = 30.0
## Radio (m) alrededor del círculo en el que una muerte alta cuenta como de la pasarela y cuánto por
## encima del suelo del círculo (m) tiene que estar.
const WALKWAY_RADIUS: float = 30.0
const WALKWAY_MIN_HEIGHT: float = 2.0
## Ticks por segundo de los datos.
const TICK_RATE: int = 60


## Resume el registro [param text] (el contenido del archivo JSON Lines). [param routes] son las rutas de
## la zona (null = las muertes se clasifican solo como pasarela u otras). Las líneas que no son JSON se
## cuentan en [code]bad_lines[/code]. Claves del resultado:
## [codeblock]
## zone, ticks, duration_s, bad_lines
## war_events    {clave del aviso: veces}
## captures      [{fortress, realm, ticks_from_cycle_start, seconds_from_cycle_start,
##                 seconds_from_captain_down, seconds_capturing}]
## gate_breaks   [{fortress, seconds}]
## deaths        {players, npcs, by_route {ruta: jugadores muertos}, by_realm {reino: jugadores muertos}}
## [/codeblock]
static func summarize(text: String, routes: ApproachRoutes = null) -> Dictionary:
	var result: Dictionary = {
		"zone": "", "ticks": 0, "duration_s": 0.0, "bad_lines": 0, "war_events": {},
		"captures": [], "gate_breaks": [],
		"deaths": {"players": 0, "npcs": 0, "by_route": {}, "by_realm": {}},
	}
	var fortresses: Dictionary = {}
	# Estado por fortaleza: tick de inicio del ciclo, de la caída del capitán, de «captura iniciada»
	# y del primer golpe a la puerta.
	var cycles: Dictionary = {}
	for line: String in text.split("\n", false):
		var parsed: Variant = JSON.parse_string(line)
		if not (parsed is Dictionary):
			result["bad_lines"] = int(result["bad_lines"]) + 1
			continue
		var entry: Dictionary = parsed
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


## Clasifica una muerte en la posición [param position] (x, y, z) como [code]walkway[/code],
## [code]bridge[/code], [code]ford[/code] u [code]other[/code]. [param fortress] es la fortaleza del
## registro (con [code]circle[/code] y [code]position[/code]) o un diccionario vacío; [param routes] las
## rutas de la zona o null.
static func classify_route(position: Array, fortress: Dictionary, routes: ApproachRoutes) -> StringName:
	if position.size() < 3:
		return OTHER
	var point := Vector2(float(position[0]), float(position[2]))
	var height: float = float(position[1])
	var circle: Array = fortress.get("circle", [])
	if circle.size() >= 3:
		var center := Vector2(float(circle[0]), float(circle[2]))
		if point.distance_to(center) <= WALKWAY_RADIUS and height >= float(circle[1]) + WALKWAY_MIN_HEIGHT:
			return WALKWAY
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


## El resumen [param summary] ([method summarize]) como texto en español, para la terminal.
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
	var by_route: Dictionary = deaths["by_route"]
	for route: String in ["bridge", "ford", "walkway", "other"]:
		var label: String = {"bridge": "puente", "ford": "vado", "walkway": "pasarela",
				"other": "otros sitios"}[route]
		lines.append("  %s: %d" % [label, int(by_route.get(route, 0))])
	var war_events: Dictionary = summary["war_events"]
	var names := PackedStringArray()
	for key: String in war_events:
		names.append("%s %d" % [key, int(war_events[key])])
	names.sort()
	lines.append("Avisos de guerra: %s" % (", ".join(names) if not names.is_empty() else "ninguno"))
	return "\n".join(lines)


# Estado del ciclo de una fortaleza (se crea al nombrarla).
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
	if String(entry.get("victim_kind", "player")) != "player":
		deaths["npcs"] = int(deaths["npcs"]) + 1
		return
	deaths["players"] = int(deaths["players"]) + 1
	var by_realm: Dictionary = deaths["by_realm"]
	var realm_key: String = str(int(entry.get("victim_realm", 0)))
	by_realm[realm_key] = int(by_realm.get(realm_key, 0)) + 1
	var fortress: Dictionary = {}
	if not fortresses.is_empty():
		fortress = fortresses[fortresses.keys()[0]]
	var route: StringName = classify_route(entry.get("position", []), fortress, routes)
	var by_route: Dictionary = deaths["by_route"]
	by_route[String(route)] = int(by_route.get(String(route), 0)) + 1


# Distancia (m) en el plano de [param point] a la poligonal [param polyline] (puntos x, z).
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
