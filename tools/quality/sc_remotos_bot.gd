extends RefCounted
## Quality capture bench (TEC-50), combat area: strips of an ISOLATED remote bot.
##
## The server runs without NPCs or dummies ([code]--no-npcs --no-dummies[/code]) and with a single bot from the enemy realm (a full
## [code]--bot --bot-brain=combat[/code] client, which uses the whole kit: abilities, block, dodge), so
## nobody else blocks or surrounds the followed one. The capture client positions itself outside the safe zone of the enemy
## camp and acts as a sparring partner ([code]spar.gd[/code]): it fights, takes cover, backs off, throws
## heavy attacks and steps aside to watch, so that the bot attacks, runs, blocks, dodges, staggers, is knocked down and dies.
## Each strip comes out of the [code]strip_recorder.gd[/code] ring with the start of the action, and its
## [code]meta.json[/code] stores per frame the clip played by the remote's animation layer.

const Recorder = preload("res://tools/quality/strip_recorder.gd")
const Spar = preload("res://tools/quality/spar.gd")
const Specs = preload("res://tools/quality/strip_specs.gd")

## Meeting point (the most open of [code]Spar.MEET_CANDIDATES[/code]): outside the safe zone of the enemy camp and in
## view of the bot. It faces the camp (increasing z, yaw 180).
const MEET_YAW: float = 180.0
const TIMEOUT_MS: int = 360000
const SWORD: String = "sword_shield"
## Rotating sparring modes: mode and duration (ms).
const MODES: Array = [["fight", 7000], ["tank", 4500], ["kite", 3500], ["heavy", 6500], ["observe", 3000], ["fight", 16000]]

var d: Variant
var rec: Variant
var spar: Variant
var specs: Variant
var _meet: Vector2 = Vector2(0.0, 105.0)
var _mode_index: int = 0
var _mode_end_ms: int = 0


func run(drv: Variant) -> void:
	d = drv
	if not await d.enter_world():
		return
	rec = Recorder.new(d)
	d.recorder = rec
	spar = Spar.new(d, 11)
	specs = Specs.new(d, rec)
	_define_specs()
	var t_end: int = Time.get_ticks_msec() + TIMEOUT_MS
	_meet = d.open_spot(Spar.MEET_CANDIDATES)
	d.note("punto de encuentro con el bot: (%.0f, %.0f)" % [_meet.x, _meet.y])
	await d.tp(_meet.x, _meet.y, MEET_YAW, 6.0, NAN, 1.0)
	while Time.get_ticks_msec() < t_end and not specs.all_done():
		await d.ensure_alive()
		var enemy: Dictionary = d.nearest_enemy(60.0)
		if enemy.is_empty():
			spar.stop()
			specs.cancel()
			rec.clear()
			d.note("sin bot a la vista: vuelta al punto de encuentro")
			await d.tp(_meet.x, _meet.y, MEET_YAW, 6.0, NAN, 1.0)
			await d.wait_healing(5.0)
			continue
		await _spar_with(enemy["view"], t_end)
	spar.stop()
	d.release_all()
	rec.clear()
	d.note("tiras del bot conseguidas: %s" % [specs.done.keys()])
	d.note("tiras del bot que no se vieron: %s (tomas descartadas por validación: %s)" % [specs.missing(), specs.rejected])


func _spar_with(view: Object, t_end: int) -> void:
	rec.follow_remote(view)
	specs.cancel()
	_mode_end_ms = 0
	var next_heal: int = 0
	while is_instance_valid(view) and Time.get_ticks_msec() < t_end:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			break
		_choose_mode(now)
		spar.step(view.get_drawn_position())
		await d.step()
		specs.evaluate("bot")
		if specs.all_done():
			break
	spar.stop()


func _choose_mode(now: int) -> void:
	var action: String = String(rec.last_meta().get("action", "NONE"))
	if action == "DOWNED" or action == "DEAD":
		# A knocked-down player is left to bleed out at a distance (the whole knockdown is seen, then the death).
		spar.set_mode("observe")
		_mode_end_ms = now + 1500
		return
	if now >= _mode_end_ms:
		var entry: Array = MODES[_mode_index % MODES.size()]
		_mode_index += 1
		spar.set_mode(String(entry[0]))
		_mode_end_ms = now + int(entry[1])


func _define_specs() -> void:
	specs.add("rem_bot_ataque", "Bot remoto: ataque ligero", "bot", Specs.edge(["LIGHT"]), 12, 100, 150,
			"Un ligero del bot, desde el principio del golpe.",
			Specs.has_action(["LIGHT"], 4, ["CHARGE", "HEAVY"], SWORD))
	specs.add("rem_bot_ataque_fuerte", "Bot remoto: ataque fuerte (carga y golpe)", "bot", Specs.edge(["CHARGE"]), 12, 150, 100,
			"Carga y golpe fuerte del bot.",
			Specs.has_action(["HEAVY"], 2, [], SWORD))
	specs.add("rem_bot_correr", "Bot remoto: correr", "bot",
			func(cur: Dictionary, prev: Dictionary) -> bool:
				return cur["action"] == "NONE" and prev["action"] == "NONE" and float(cur["speed"]) > 4.5 \
						and float(prev["speed"]) > 4.5,
			12, 90, 0, "El bot corriendo hacia el jugador.",
			func(metas: Array, info: Dictionary) -> bool:
				if String(info.get("weapon", "")) != SWORD:
					return false
				for m: Dictionary in metas:
					if m["action"] != "NONE" or float(m["speed"]) < 3.0:
						return false
				return true)
	specs.add("rem_bot_bloqueo", "Bot remoto: bloqueo", "bot", Specs.edge(["BLOCK"]), 12, 120, 150,
			"Entrada y mantenimiento del bloqueo del bot.",
			Specs.has_action(["BLOCK"], 5, [], SWORD))
	specs.add("rem_bot_esquiva", "Bot remoto: esquiva", "bot", Specs.edge(["DODGE"]), 12, 50, 100,
			"Esquiva del bot (27 ticks).",
			Specs.has_action(["DODGE"], 6, [], SWORD))
	specs.add("rem_bot_recibir_golpe", "Bot remoto: recibir golpe (tambaleo)", "bot", Specs.edge(["STAGGER"]), 12, 50, 100,
			"El bot tambaleándose tras un golpe del jugador.",
			Specs.has_action(["STAGGER"], 4, [], SWORD))
	specs.add("rem_bot_habilidad", "Bot remoto: habilidad", "bot", Specs.edge(["ABILITY"]), 12, 100, 150,
			"El bot usando una habilidad de espada y escudo.",
			Specs.has_action(["ABILITY"], 3, [], SWORD))
	specs.add("rem_bot_derribado", "Bot remoto: derribado", "bot", Specs.edge(["DOWNED"]), 12, 200, 200,
			"El bot derribado (vivo, en el suelo).",
			Specs.has_action(["DOWNED"], 6), true)
	specs.add("rem_bot_muerte", "Bot remoto: muerte", "bot", Specs.edge(["DEAD"]), 12, 200, 200,
			"El bot muriendo.",
			Specs.has_action(["DEAD"], 4), true)
