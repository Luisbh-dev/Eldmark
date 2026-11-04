extends RefCounted
## Quality capture bench (TEC-50), combat area: brawls at the Vado Gris fort.
##
## With the bots of both realms ([code]--bot-brain=siege[/code]), the Hollow and the captain fighting around, the client
## teleports to the busiest point of the fort (or to the gate if nobody is there) and fights with
## [code]Input.action_press[/code] (approach, light attacks, abilities, dodge, block). Every ~0.9 s it saves a capture with HUD
## ([code]combate/pelea_NN.png[/code]) and at the end a sequence with the shield up while being attacked
## ([code]combate/bloqueo_recibiendo_NN.png[/code]). With the tag [code]*_b[/code] ([code]--tag=combate_b[/code]) it resets the
## fort every two rounds so that the Hollow and the captain come back, and the files carry [code]_b[/code].
## [br][br]
## The animation strips of the characters seen from this client no longer come from here (other combatants blocked them):
## they are in [code]sc_remotos_bot.gd[/code], [code]sc_remotos_pnj.gd[/code] and [code]sc_bloqueo.gd[/code].

const Spar = preload("res://tools/quality/spar.gd")

const SHOTS: int = 50
const SHOT_GAP_S: float = 0.9
const TIMEOUT_MS: int = 200000

var d: Variant
var shot_n: int = 0
var prefix: String = ""
var reset_fort: bool = false
var round_n: int = 0
var _rng := RandomNumberGenerator.new()
var _spar: Variant


func run(drv: Variant) -> void:
	d = drv
	if String(d.tag).ends_with("_b"):
		prefix = "b_"
		reset_fort = true
	_rng.seed = 7 if prefix == "" else 11
	if not await d.enter_world():
		return
	_spar = Spar.new(d, _rng.seed)
	_spar.look_offset_deg = 0.0
	await d.wait(1.0)
	# Fight rounds at the busiest point of the fort (or at the gate if nobody is there).
	var t_end: int = Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < t_end and shot_n < SHOTS:
		round_n += 1
		await d.ensure_alive()
		await _go_to_battle()
		await _fight(13.0, SHOT_GAP_S)
	d.release_all()
	await d.ensure_alive()
	await _block_sequence()


func _go_to_battle() -> void:
	if reset_fort and round_n % 2 == 1:
		d.cmd(NetProtocol.DEBUG_FORT_RESET)
		await d.wait_healing(3.5)
		await d.tp(-24.0, 0.0, -90.0, 5.0, NAN, 0.8)
		return
	var spot: Dictionary = d.busiest_spot(10.0, 3, true)
	if spot.is_empty():
		d.note("sin combate a la vista: se va a la puerta del fuerte")
		await d.tp(-26.0, 0.0, -90.0, 5.0, NAN, 1.0)
		return
	var c: Vector3 = spot["center"]
	var angle: float = _rng.randf() * TAU
	var from: Vector3 = c + Vector3(cos(angle) * 5.5, 0.0, sin(angle) * 5.5)
	await d.tp(from.x, from.z, d.yaw_to(from.x, from.z, c.x, c.z), 8.0, NAN, 0.6)


func _fight(seconds: float, shot_gap: float) -> void:
	var end: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	var next_shot: int = Time.get_ticks_msec() + 500
	var next_heal: int = 0
	_spar.set_mode("fight")
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
		if now >= next_shot and shot_n < SHOTS + 20:
			shot_n += 1
			next_shot = now + int(shot_gap * 1000.0)
			await d.shot("combate/pelea_%s%02d.png" % [prefix, shot_n], "plena pelea en el fuerte entre varios personajes (bots de los dos reinos, Huecos y capitán), toma %d" % shot_n,
					"cliente combatiendo con Input.action_press; teletransporte al punto más concurrido")
		await d.step()
	_spar.stop()
	d.release_all()


func _block_sequence() -> void:
	# Blocking while taking hits: next to a Hollow, with the shield up.
	await d.tp(-26.0, 0.0, -90.0, 6.0, NAN, 0.8)
	_spar.set_mode("tank")
	var end: int = Time.get_ticks_msec() + 24000
	var n: int = 0
	var next_shot: int = Time.get_ticks_msec() + 1500
	var next_heal: int = 0
	while Time.get_ticks_msec() < end and n < 10:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			await d.ensure_alive()
			await d.tp(-26.0, 0.0, -90.0, 6.0, NAN, 0.8)
		var enemy: Dictionary = d.nearest_enemy(30.0)
		if not enemy.is_empty():
			_spar.step(enemy["pos"])
		if now >= next_shot:
			n += 1
			next_shot = now + 2000
			await d.shot("combate/bloqueo_recibiendo_%s%02d.png" % [prefix, n], "bloqueando con el escudo mientras los PNJ y bots atacan (%d)" % n,
					"Input.action_press(block) mantenido junto al enemigo más cercano")
		await d.step()
	_spar.stop()
	d.release_all()
