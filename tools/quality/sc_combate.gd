extends RefCounted
## Quality capture bench (TEC-50), combat area: brawls in the courtyard of the Vado Gris fort.
##
## The closed gate does not let anyone in on foot, so every round the client resets the fort (debug command 8: the four
## Hollow and the Ford Captain come back) and teleports into the courtyard, where the fight is. Per round:
## [br]- [code]combate/huecos_20m_NN.png[/code]: a Hollow seen from about 20 m, before fighting.
## [br]- [code]combate/pelea_NN.png[/code]: fights with [code]Input.action_press[/code] (approach, light attacks, abilities, dodge,
## block, heavy attacks) and saves a capture with HUD every ~1.3 s; also one at the instant of every hit dealt
## ([code]combate/golpe_NN.png[/code], with damage numbers).
## [br]- [code]combate/bloqueo_recibiendo_NN.png[/code]: shield up next to an enemy, one capture the moment a hit is blocked
## (block spark), at most one every 1.2 s.
## [br]- [code]combate/esquiva_NN.png[/code]: a dodge, captured 0.15 s after pressing it.
## With the tag [code]*_b[/code] ([code]--tag=combate_b[/code]) the files carry [code]_b[/code] and the seed changes.
## [br][br]
## The animation strips of the characters seen from this client no longer come from here (other combatants blocked them):
## they are in [code]sc_remotos_bot.gd[/code], [code]sc_remotos_pnj.gd[/code] and [code]sc_bloqueo.gd[/code].

const Spar = preload("res://tools/quality/spar.gd")

## Courtyard spots (inside the 40 x 40 m palisade) to see a Hollow from about 20 m, with a clear line of sight.
const FAR_SPOTS: Array = [Vector2(-16.0, -16.0), Vector2(-16.0, -8.0), Vector2(-16.0, 0.0), Vector2(-16.0, 8.0), Vector2(-16.0, 16.0),
		Vector2(-8.0, -16.0), Vector2(-8.0, 16.0), Vector2(0.0, -16.0), Vector2(0.0, 16.0), Vector2(8.0, -16.0),
		Vector2(8.0, 16.0), Vector2(16.0, -16.0), Vector2(16.0, -8.0), Vector2(16.0, 0.0), Vector2(16.0, 8.0), Vector2(16.0, 16.0)]
## Open spots to start the fight (fewest obstacles around).
const FIGHT_SPOTS: Array = [Vector2(-12.0, -6.0), Vector2(-12.0, 6.0), Vector2(-14.0, 0.0), Vector2(8.0, -14.0), Vector2(8.0, 14.0),
		Vector2(14.0, 0.0)]
const ROUNDS: int = 4
const FIGHT_SECONDS: float = 16.0
const SHOT_GAP_S: float = 1.3
const TIMEOUT_MS: int = 260000

var d: Variant
var prefix: String = ""
var round_n: int = 0
var _rng := RandomNumberGenerator.new()
var _spar: Variant
var _counts: Dictionary = {"pelea": 0, "golpe": 0, "bloqueo": 0, "esquiva": 0, "huecos": 0}
var _seen_ms: int = 0


func run(drv: Variant) -> void:
	d = drv
	if String(d.tag).ends_with("_b"):
		prefix = "b_"
	_rng.seed = 7 if prefix == "" else 11
	if not await d.enter_world():
		return
	_spar = Spar.new(d, _rng.seed)
	_spar.look_offset_deg = 0.0
	await d.wait(1.0)
	var t_end: int = Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < t_end and round_n < ROUNDS:
		round_n += 1
		await d.ensure_alive()
		await _enter_courtyard()
		await _far_shot()
		await _fight(FIGHT_SECONDS)
		await _block_sequence(4)
		await _dodge_sequence(2)
	d.release_all()


# Resets the fort (all its Hollow and the Captain come back) and teleports to the courtyard.
func _enter_courtyard() -> void:
	d.release_all()
	d.cmd(NetProtocol.DEBUG_FORT_RESET)
	await d.wait_healing(3.5)
	var spot: Vector2 = d.open_spot(FIGHT_SPOTS)
	await d.tp(spot.x, spot.y, d.yaw_to(spot.x, spot.y, 0.0, 0.0), 5.0, NAN, 0.8)


# A Hollow seen from about 20 m: tries the courtyard spots by closeness to that distance (with a clear line of sight to
# an enemy that has not moved yet) and keeps the first one where, after teleporting, the enemy is still in the middle of the screen.
func _far_shot() -> void:
	var options: Array = []
	for spot: Vector2 in FAR_SPOTS:
		for e: Dictionary in d.remotes():
			if int(e["kind"]) != NetProtocol.EntityKind.NPC or String(e["name"]).begins_with("Mani"):
				continue
			var dist: float = Vector2(e["pos"].x - spot.x, e["pos"].z - spot.y).length()
			if absf(dist - 20.0) < 4.0 and _clear_view(spot, e["pos"]):
				options.append({"spot": spot, "err": absf(dist - 20.0), "id": e["id"]})
	options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["err"]) < float(b["err"]))
	for i: int in mini(options.size(), 4):
		var spot: Vector2 = options[i]["spot"]
		var target: Dictionary = {}
		for e: Dictionary in d.remotes():
			if e["id"] == options[i]["id"]:
				target = e
		if target.is_empty():
			continue
		await d.tp(spot.x, spot.y, d.yaw_to(spot.x, spot.y, target["pos"].x, target["pos"].z), 3.0, NAN, 0.1)
		for e: Dictionary in d.remotes():
			if e["id"] != options[i]["id"]:
				continue
			var p: Vector2 = d.to_screen(e["pos"] + Vector3(0.0, 1.0, 0.0))
			var size: Vector2 = d.root.get_visible_rect().size
			if absf(p.x / size.x - 0.5) < 0.2 and _clear_view(Vector2(d.pos().x, d.pos().z), e["pos"]) and float(e["dist"]) > 16.0:
				_counts["huecos"] += 1
				await d.shot("combate/huecos_20m_%s%02d.png" % [prefix, _counts["huecos"]], "un Hueco visto a unos %.0f m, sin placa" % e["dist"],
						"teletransporte a un punto del patio a ~20 m de un enemigo, mirando hacia él")
				return
	d.note("sin toma válida de un Hueco a 20 m en esta ronda")


# true if no solid thing is between a character standing at [param spot] and [param target] (rays at chest height).
func _clear_view(spot: Vector2, target: Vector3) -> bool:
	var world: Node3D = d.main.get_world() as Node3D
	if world == null:
		return true
	var gy: float = d.ground_y(spot.x, spot.y)
	if absf(gy - target.y) > 2.0:
		return false
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(Vector3(spot.x, gy + 1.5, spot.y), target + Vector3(0.0, 1.5, 0.0), 1)
	return space.intersect_ray(query).is_empty()


func _fight(seconds: float) -> void:
	var end: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	var next_shot: int = Time.get_ticks_msec() + 900
	var next_heal: int = 0
	var last_hit_shot: int = 0
	_spar.set_mode("fight")
	_seen_ms = Time.get_ticks_msec()
	while Time.get_ticks_msec() < end:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			break
		var enemy: Dictionary = d.nearest_enemy(40.0)
		if not enemy.is_empty():
			_spar.step(enemy["pos"])
		if _fresh_event("dealt", false) and now - last_hit_shot > 1500 and _counts["golpe"] < 14:
			last_hit_shot = now
			_counts["golpe"] += 1
			await d.shot("combate/golpe_%s%02d.png" % [prefix, _counts["golpe"]], "instante de un golpe propio con el número de daño",
					"captura en el fotograma en que llega el evento de golpe confirmado")
		elif now >= next_shot and _counts["pelea"] < 40:
			_counts["pelea"] += 1
			next_shot = now + int(SHOT_GAP_S * 1000.0)
			await d.shot("combate/pelea_%s%02d.png" % [prefix, _counts["pelea"]], "pelea en el patio del fuerte contra los Huecos y el capitán, toma %d" % _counts["pelea"],
					"cliente combatiendo con Input.action_press tras restablecer el fuerte")
		await d.step()
	_spar.stop()
	d.release_all()


# Shield up next to the nearest enemy: one capture the moment a hit is blocked (so the spark is on screen).
func _block_sequence(max_shots: int) -> void:
	await d.ensure_alive()
	var enemy: Dictionary = d.nearest_enemy(40.0)
	if enemy.is_empty():
		return
	_spar.set_mode("tank")
	var end: int = Time.get_ticks_msec() + 14000
	var n: int = 0
	var next_heal: int = 0
	var last_shot: int = 0
	_seen_ms = Time.get_ticks_msec()
	while Time.get_ticks_msec() < end and n < max_shots:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			break
		enemy = d.nearest_enemy(40.0)
		if not enemy.is_empty():
			_spar.step(enemy["pos"])
		if _fresh_event("taken", true) and now - last_shot > 1200:
			last_shot = now
			n += 1
			_counts["bloqueo"] += 1
			await d.shot("combate/bloqueo_recibiendo_%s%02d.png" % [prefix, _counts["bloqueo"]], "golpe bloqueado con el escudo (chispa), toma %d" % _counts["bloqueo"],
					"Input.action_press(block) mantenido; captura en el fotograma del evento de golpe bloqueado")
		await d.step()
	_spar.stop()
	d.release_all()


# A dodge pressed next to an enemy, captured 0.15 s later.
func _dodge_sequence(count: int) -> void:
	await d.ensure_alive()
	_spar.set_mode("fight")
	for i: int in count:
		var until: int = Time.get_ticks_msec() + 2500
		while Time.get_ticks_msec() < until:
			d.heal()
			var enemy: Dictionary = d.nearest_enemy(40.0)
			if enemy.is_empty():
				break
			_spar.step(enemy["pos"])
			await d.step()
		_spar.stop()
		d.release_all()
		d.hold(&"move_forward")
		d.tap(&"dodge", 4)
		await d.wait(0.15)
		_counts["esquiva"] += 1
		await d.shot("combate/esquiva_%s%02d.png" % [prefix, _counts["esquiva"]], "esquiva a los 0,15 s de pulsarla",
				"Input.action_press(dodge) con el enemigo cerca")
		d.release(&"move_forward")
		await d.wait(0.8)
	_spar.stop()
	d.release_all()


# true if, since the last call, a hit of [param kind] ("taken" blocked, or "dealt") arrived.
func _fresh_event(kind: String, blocked: bool) -> bool:
	var found: bool = false
	var newest: int = _seen_ms
	for ev: Dictionary in d.hit_events:
		if int(ev["ms"]) <= _seen_ms:
			continue
		newest = maxi(newest, int(ev["ms"]))
		if String(ev["kind"]) == kind and bool(ev["blocked"]) == blocked:
			found = true
	_seen_ms = newest
	return found
