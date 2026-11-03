extends RefCounted
## Banco de capturas de calidad (TEC-50), área combate: tiras de los PNJ vistos desde otro cliente de verdad.
##
## Cuatro fases, una por tipo de PNJ, con el servidor por defecto (PNJ del Vado Gris, sin bots):
## [br]- [code]hueco[/code]: los Huecos de la guarnición neutral del fuerte.
## [br]- [code]capitan[/code]: el Capitán del Vado (su muerte la fuerza el comando de depuración «matar al capitán»).
## [br]- [code]guardia[/code]: los guardias de reino y el capitán de reino; para tenerlos enemigos se da el fuerte al
## reino contrario con el comando de depuración (la guarnición aparece al momento).
## [br]- [code]guardian[/code]: los Guardianes de la Puerta del campamento enemigo (atacan a quien entra en él).
## En cada fase se elige el PNJ más alejado de los demás, el cliente se coloca al lado contrario de sus compañeros y
## hace de compañero de entrenamiento ([code]spar.gd[/code]); [code]strip_recorder.gd[/code] graba las tiras con el clip de
## la capa de animación del PNJ en cada fotograma. Con [code]--phases=hueco,guardia[/code] se eligen las fases.

const Recorder = preload("res://tools/quality/strip_recorder.gd")
const Spar = preload("res://tools/quality/spar.gd")
const Specs = preload("res://tools/quality/strip_specs.gd")

const FORT_GATE_SPOT: Vector3 = Vector3(-26.0, 0.0, 0.0)
const ENEMY_CAMP_SPOT: Vector3 = Vector3(0.0, 0.0, 128.0)
## Tiempo máximo (ms) de cada fase y de toda la ejecución.
const PHASE_BUDGET_MS: int = 150000
const TIMEOUT_MS: int = 700000
const MODES: Array = [["fight", 9000], ["observe", 3000], ["heavy", 6000], ["kite", 4000], ["fight", 20000]]

var d: Variant
var rec: Variant
var spar: Variant
var specs: Variant
var _phases: PackedStringArray = PackedStringArray(["hueco", "capitan", "guardia", "guardian"])
var _mode_index: int = 0
var _mode_end_ms: int = 0
var _captain_killed: bool = false


func run(drv: Variant) -> void:
	d = drv
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--phases="):
			_phases = arg.trim_prefix("--phases=").split(",", false)
	if not await d.enter_world():
		return
	rec = Recorder.new(d)
	d.recorder = rec
	spar = Spar.new(d, 13)
	specs = Specs.new(d, rec)
	_define_specs()
	var t_end: int = Time.get_ticks_msec() + TIMEOUT_MS
	for phase: String in _phases:
		if Time.get_ticks_msec() >= t_end:
			break
		await _phase(phase, mini(Time.get_ticks_msec() + PHASE_BUDGET_MS, t_end))
	spar.stop()
	d.release_all()
	rec.clear()
	d.note("tiras de PNJ conseguidas: %s" % [specs.done.keys()])
	var missing := PackedStringArray()
	for phase_key: String in _phases:
		missing.append_array(specs.missing(phase_key))
	d.note("tiras de PNJ que no se vieron en las fases pedidas: %s (tomas descartadas por validación: %s)" % [missing, specs.rejected])


# --- Fases -------------------------------------------------------------------------------------

func _phase(key: String, phase_end: int) -> void:
	d.note("fase %s" % key)
	await d.ensure_alive()
	_captain_killed = false
	match key:
		"hueco", "capitan":
			d.cmd(NetProtocol.DEBUG_FORT_RESET)
			await d.wait_healing(3.0)
		"guardia":
			d.cmd(NetProtocol.DEBUG_FORT_RESET)
			await d.wait_healing(2.0)
			var enemy_realm: int = NetProtocol.Realm.SOLMARCH if d.client.get_config().realm == NetProtocol.Realm.VARDHEIM \
					else NetProtocol.Realm.VARDHEIM
			d.cmd(NetProtocol.DEBUG_FORT_OWNER, PackedByteArray([enemy_realm]))
			await d.wait_healing(2.5)
		"guardian":
			await d.tp(ENEMY_CAMP_SPOT.x, ENEMY_CAMP_SPOT.z, 0.0, 6.0, NAN, 1.0)
	var misses: int = 0
	while Time.get_ticks_msec() < phase_end and not specs.all_done(key):
		await d.ensure_alive()
		var target: Dictionary = _pick_target(key)
		if target.is_empty():
			misses += 1
			if misses > 3:
				d.note("fase %s: no hay %s a la vista, se pasa a la siguiente" % [key, key])
				break
			await d.tp(FORT_GATE_SPOT.x, FORT_GATE_SPOT.z, -90.0, 6.0, NAN, 1.0)
			await d.wait_healing(2.0)
			continue
		d.note("fase %s: objetivo %s a %.1f m" % [key, target["name"], target["dist"]])
		await _approach_and_spar(target, key, phase_end)
	spar.stop()
	rec.clear()
	specs.cancel()


func _matches(key: String, npc_name: String) -> bool:
	match key:
		"hueco":
			return npc_name.begins_with("Hueco")
		"capitan":
			return npc_name.begins_with("Capit")
		"guardia":
			return npc_name.begins_with("Guardia del")
		"guardian":
			return npc_name.begins_with("Guardián")
	return false


# El PNJ de la fase más alejado de los demás PNJ (para que ninguno lo rodee), vivo y a la vista.
func _pick_target(key: String) -> Dictionary:
	var all: Array = d.remotes()
	var best: Dictionary = {}
	var best_gap: float = -1.0
	var my_realm: int = d.client.get_config().realm
	for r: Dictionary in all:
		if int(r["kind"]) != NetProtocol.EntityKind.NPC or not _matches(key, String(r["name"])):
			continue
		if (int(r["action"]) & 0x0F) == CombatState.Action.DEAD:
			continue
		# Los PNJ de reino (guardias, Guardianes) tienen que ser del reino contrario: los propios no atacan.
		if int(r["realm"]) == my_realm:
			continue
		if key == "guardian":
			# Los dos Guardianes de una puerta están juntos: vale el más cercano.
			if best.is_empty() or float(r["dist"]) < float(best["dist"]):
				best = r
			continue
		var gap: float = 1000.0
		for o: Dictionary in all:
			if o["id"] == r["id"] or int(o["kind"]) != NetProtocol.EntityKind.NPC:
				continue
			gap = minf(gap, (o["pos"] as Vector3).distance_to(r["pos"]))
		if gap > best_gap:
			best_gap = gap
			best = r
	return best


# Un punto a 6 m del PNJ por el lado contrario al de su vecino más cercano (así los demás quedan a su espalda).
func _spot_for(target: Dictionary) -> Vector3:
	var p: Vector3 = target["pos"]
	var away := Vector3.ZERO
	for o: Dictionary in d.remotes():
		if o["id"] == target["id"] or int(o["kind"]) != NetProtocol.EntityKind.NPC:
			continue
		var v: Vector3 = p - (o["pos"] as Vector3)
		v.y = 0.0
		if v.length() < 40.0:
			away += v.normalized() / maxf(v.length(), 1.0)
	if away.length() < 0.001:
		away = Vector3(-1.0, 0.0, 0.0)
	away = away.normalized()
	return p + away * 6.0


func _approach_and_spar(target: Dictionary, key: String, phase_end: int) -> void:
	var view: Object = target["view"]
	var me: Vector3 = d.pos()
	if key != "guardian" and me.distance_to(target["pos"]) > 14.0:
		var spot: Vector3 = _spot_for(target)
		var yaw: float = d.yaw_to(spot.x, spot.z, target["pos"].x, target["pos"].z)
		await d.tp(spot.x, spot.z, yaw, 6.0, NAN, 1.0)
	rec.follow_remote(view)
	specs.cancel()
	_mode_end_ms = 0
	var next_heal: int = 0
	var next_report: int = Time.get_ticks_msec() + 15000
	while is_instance_valid(view) and Time.get_ticks_msec() < phase_end:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if now >= next_report:
			next_report = now + 15000
			d.note("fase %s: sigo a %s a %.1f m (%s, modo %s); faltan %s" % [key, view.get_display_name(),
					view.get_drawn_position().distance_to(d.pos()), rec.last_meta().get("action", "?"), spar.mode,
					specs.missing(key)])
		if d.client.is_dead() or d.client.is_downed():
			d.note("fase %s: el cliente cayó, se levanta" % key)
			break
		_maybe_kill_captain(key)
		_choose_mode(now)
		spar.step(view.get_drawn_position())
		await d.step()
		specs.evaluate(key)
		if specs.all_done(key):
			break
		if view.get_drawn_position().distance_to(d.pos()) > 60.0:
			d.note("fase %s: el objetivo quedó a más de 60 m, se busca otro" % key)
			break
	spar.stop()


# Con el resto de tiras del capitán hechas, se le mata con el comando de depuración para ver su muerte desde lejos.
func _maybe_kill_captain(key: String) -> void:
	if key != "capitan" or _captain_killed:
		return
	for id: String in specs.missing("capitan"):
		if id != "rem_capitan_muerte":
			return
	_captain_killed = true
	d.cmd(NetProtocol.DEBUG_FORT_KILL_CAPTAIN)


func _choose_mode(now: int) -> void:
	var action: String = String(rec.last_meta().get("action", "NONE"))
	if action == "DEAD" or action == "DOWNED" or _captain_killed:
		spar.set_mode("observe")
		_mode_end_ms = now + 1500
		return
	if now >= _mode_end_ms:
		var entry: Array = MODES[_mode_index % MODES.size()]
		_mode_index += 1
		spar.set_mode(String(entry[0]))
		_mode_end_ms = now + int(entry[1])


# --- Tiras ------------------------------------------------------------------------------------

func _walk_cond() -> Callable:
	return func(cur: Dictionary, prev: Dictionary) -> bool:
		return cur["action"] == "NONE" and prev["action"] == "NONE" and float(cur["speed"]) > 1.0 \
				and float(prev["speed"]) > 1.0


func _walk_valid(weapon: String) -> Callable:
	return func(metas: Array, info: Dictionary) -> bool:
		if String(info.get("weapon", "")) != weapon:
			return false
		var moving: int = 0
		for m: Dictionary in metas:
			if m["action"] != "NONE":
				return false
			if float(m["speed"]) >= 0.8:
				moving += 1
		# Se mueve en la mayor parte de la toma (al llegar al jugador frena en los últimos fotogramas).
		return moving >= 8


func _define_specs() -> void:
	# Hueco (weapon npc_hollow).
	var hollow: String = "npc_hollow"
	specs.add("rem_hueco_ataque", "Hueco visto desde otro cliente: ataque", "hueco", Specs.edge(["LIGHT"]), 12, 100, 150,
			"Un ataque ligero del Hueco, desde el principio del golpe.",
			Specs.has_action(["LIGHT"], 3, ["CHARGE", "HEAVY"], hollow))
	specs.add("rem_hueco_ataque_fuerte", "Hueco visto desde otro cliente: ataque fuerte", "hueco", Specs.edge(["CHARGE"]), 12, 150, 100,
			"Carga y golpe fuerte (el imparable) del Hueco.", Specs.has_action(["HEAVY"], 1, [], hollow))
	specs.add("rem_hueco_andar", "Hueco visto desde otro cliente: andar/correr", "hueco", _walk_cond(), 12, 120, 0,
			"El Hueco desplazándose.", _walk_valid(hollow))
	specs.add("rem_hueco_recibir_golpe", "Hueco visto desde otro cliente: recibir golpe", "hueco", Specs.edge(["STAGGER"]), 12, 60, 100,
			"El Hueco tambaleándose tras un golpe del jugador.", Specs.has_action(["STAGGER"], 3, [], hollow))
	specs.add("rem_hueco_muerte", "Hueco visto desde otro cliente: muerte", "hueco", Specs.edge(["DEAD"]), 12, 200, 200,
			"El Hueco muriendo.", Specs.has_action(["DEAD"], 4, [], hollow), true)
	# Capitán (weapon npc_captain).
	var captain: String = "npc_captain"
	specs.add("rem_capitan_ataque", "Capitán visto desde otro cliente: ataque", "capitan", Specs.edge(["LIGHT"]), 12, 120, 150,
			"Ataque ligero (barrido) del Capitán.", Specs.has_action(["LIGHT"], 3, ["CHARGE", "HEAVY"], captain))
	specs.add("rem_capitan_ataque_fuerte", "Capitán visto desde otro cliente: ataque fuerte", "capitan", Specs.edge(["CHARGE"]), 12, 150, 100,
			"Carga y golpe fuerte (aplastar) del Capitán.", Specs.has_action(["HEAVY"], 1, [], captain))
	specs.add("rem_capitan_andar", "Capitán visto desde otro cliente: andar/correr", "capitan", _walk_cond(), 12, 120, 0,
			"El Capitán desplazándose.", _walk_valid(captain))
	specs.add("rem_capitan_muerte", "Capitán visto desde otro cliente: muerte", "capitan", Specs.edge(["DEAD"]), 12, 200, 200,
			"El Capitán muriendo.", Specs.has_action(["DEAD"], 4, [], captain), true)
	# Guardia de reino (weapon npc_guard).
	var guard: String = "npc_guard"
	specs.add("rem_guardia_ataque", "Guardia de reino visto desde otro cliente: ataque", "guardia", Specs.edge(["LIGHT"]), 12, 100, 150,
			"Ataque ligero del guardia de reino.", Specs.has_action(["LIGHT"], 3, ["CHARGE", "HEAVY"], guard))
	specs.add("rem_guardia_ataque_fuerte", "Guardia de reino visto desde otro cliente: ataque fuerte", "guardia", Specs.edge(["CHARGE"]), 12, 150, 100,
			"Carga y golpe fuerte del guardia de reino.", Specs.has_action(["HEAVY"], 1, [], guard))
	specs.add("rem_guardia_bloqueo", "Guardia de reino visto desde otro cliente: bloqueo", "guardia", Specs.edge(["BLOCK"]), 12, 120, 150,
			"Bloqueo del guardia de reino.", Specs.has_action(["BLOCK"], 4, [], guard))
	specs.add("rem_guardia_andar", "Guardia de reino visto desde otro cliente: andar/correr", "guardia", _walk_cond(), 12, 120, 0,
			"El guardia de reino desplazándose.", _walk_valid(guard))
	specs.add("rem_guardia_muerte", "Guardia de reino visto desde otro cliente: muerte", "guardia", Specs.edge(["DEAD"]), 12, 200, 200,
			"El guardia de reino muriendo.", Specs.has_action(["DEAD"], 4, [], guard), true)
	# Guardián de la Puerta (weapon npc_guardian).
	var guardian: String = "npc_guardian"
	specs.add("rem_guardian_ataque", "Guardián de la Puerta visto desde otro cliente: ataque", "guardian", Specs.edge(["LIGHT"]), 12, 100, 150,
			"Ataque de alabarda del Guardián de la Puerta.", Specs.has_action(["LIGHT"], 3, ["CHARGE", "HEAVY"], guardian))
	specs.add("rem_guardian_andar", "Guardián de la Puerta visto desde otro cliente: andar/correr", "guardian", _walk_cond(), 12, 120, 0,
			"El Guardián de la Puerta persiguiendo a un intruso.", _walk_valid(guardian))
