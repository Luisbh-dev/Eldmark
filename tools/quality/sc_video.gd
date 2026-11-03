extends RefCounted
## Banco de capturas de calidad (TEC-50), vídeo: un minuto de combate con el modo Movie Maker del motor.
##
## Pensado para lanzarse con [code]--write-movie <archivo.avi>[/code] (lo hace [code]run.py video[/code]): el motor graba cada
## fotograma y el audio del bus maestro, así que sirve para juzgar lo que las capturas no enseñan: sonido, parada de golpe y
## fluidez. El conductor frena el juego a tiempo real mientras graba ([code]online_driver.gd[/code]), de modo que el servidor
## y el cliente siguen sincronizados.
## [br][br]
## Guion (por fotogramas, así que dura lo mismo grabado que sin grabar): los primeros 45 % contra los Huecos y el Capitán del
## fuerte (comando de depuración 8 para que estén todos) y el resto contra un bot enemigo de combate, delante de su campamento.
## El cliente pelea con [code]spar.gd[/code] (ligeros, habilidades, esquiva, bloqueo y fuertes). Duración con
## [code]--seconds=N[/code] (60 por defecto).

const Spar = preload("res://tools/quality/spar.gd")

const FPS: int = 60
## Patio del fuerte (la puerta cerrada no deja pasar a pie): el cliente aparece dentro, cerca del Capitán y de los Huecos.
const FORT_SPOT: Vector3 = Vector3(-12.0, 0.0, -6.0)
const FORT_YAW: float = -60.0

var d: Variant
var spar: Variant
var _bot_spot: Vector2 = Vector2(0.0, 105.0)
var _seconds: int = 60
var _start_frame: int = 0


func run(drv: Variant) -> void:
	d = drv
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			_seconds = clampi(int(arg.trim_prefix("--seconds=")), 10, 600)
	if not await d.enter_world():
		return
	spar = Spar.new(d, 21)
	spar.look_offset_deg = 0.0
	_bot_spot = d.open_spot(Spar.MEET_CANDIDATES)
	# Fuerte lleno de PNJ y el cliente a la puerta.
	d.cmd(NetProtocol.DEBUG_FORT_RESET)
	await d.wait_healing(3.0)
	await d.tp(FORT_SPOT.x, FORT_SPOT.z, FORT_YAW, 5.0, NAN, 1.0)
	_start_frame = Engine.get_process_frames()
	d.note("vídeo: %d s (%d fotogramas a %d por segundo)" % [_seconds, _seconds * FPS, FPS])
	await _fight_until(0.45, "npc")
	await d.ensure_alive()
	await d.tp(_bot_spot.x, _bot_spot.y, 180.0, 6.0, NAN, 1.0)
	await _fight_until(1.0, "player")
	spar.stop()
	d.release_all()
	d.note("vídeo: fin del guion tras %d fotogramas" % (Engine.get_process_frames() - _start_frame))


func _elapsed_fraction() -> float:
	return float(Engine.get_process_frames() - _start_frame) / float(_seconds * FPS)


# Pelea con el enemigo más cercano del tipo pedido hasta que pase la fracción [param until] del vídeo.
func _fight_until(until: float, kind: String) -> void:
	var next_heal: int = 0
	spar.set_mode("fight")
	var heavy_next: int = Time.get_ticks_msec() + 6000
	while _elapsed_fraction() < until:
		var now: int = Time.get_ticks_msec()
		if now >= next_heal:
			d.heal()
			next_heal = now + 300
		if d.client.is_dead() or d.client.is_downed():
			spar.stop()
			await d.ensure_alive()
			if kind == "npc":
				await d.tp(FORT_SPOT.x, FORT_SPOT.z, FORT_YAW, 5.0, NAN, 0.6)
			else:
				await d.tp(_bot_spot.x, _bot_spot.y, 180.0, 6.0, NAN, 0.6)
		var enemy: Dictionary = _nearest(kind)
		if enemy.is_empty():
			spar.stop()
			await d.step()
			continue
		# De vez en cuando, un golpe fuerte cargado para ver la parada de golpe y el derribo.
		if now >= heavy_next and spar.mode == "fight":
			spar.set_mode("heavy")
			heavy_next = now + 5000
		elif spar.mode == "heavy" and now >= heavy_next - 3200:
			spar.set_mode("fight")
		spar.step(enemy["pos"])
		await d.step()
	spar.stop()


func _nearest(kind: String) -> Dictionary:
	var my_realm: int = d.client.get_config().realm
	for r: Dictionary in d.remotes():
		if float(r["dist"]) > 45.0:
			break
		if int(r["realm"]) == my_realm or (int(r["action"]) & 0x0F) == CombatState.Action.DEAD:
			continue
		var is_npc: bool = int(r["kind"]) == NetProtocol.EntityKind.NPC
		if is_npc and String(r["name"]).begins_with("Mani"):
			continue
		if (kind == "npc") == is_npc:
			return r
	return {}
