extends RefCounted
## Quality capture bench (TEC-50), interfaz area (scenario of online_driver.gd).
##
## Tab scoreboard with players, boss bar and knocked-down notice.

var d: Variant


func run(drv: Variant) -> void:
	d = drv
	if not await d.enter_world():
		return
	await d.wait(1.5)
	# Scoreboard (Tab) with the bots in it, at three moments.
	for i: int in (0 if String(d.tag).ends_with("_boss") else 3):
		await d.ensure_alive()
		await d.tp(0.0, -134.0, 180.0, 4.0, NAN, 1.0)
		d.key_down(KEY_TAB)
		await d.wait(0.8)
		await d.shot("interfaz/marcador_tab_%d.png" % (i + 1), "marcador de la zona (Tab mantenido), toma %d" % (i + 1), "InputEventKey Tab mantenido")
		d.key_up(KEY_TAB)
		await d.wait_healing(18.0 if i < 2 else 0.5)
	# Boss bar: fight against the Ford Captain.
	await d.ensure_alive()
	d.cmd(NetProtocol.DEBUG_FORT_RESET)
	await d.wait_healing(2.0)
	await d.tp(-14.0, 2.0, -60.0, 4.0, NAN, 0.8)
	var end: int = Time.get_ticks_msec() + 14000
	var shots: int = 0
	var next_shot: int = Time.get_ticks_msec() + 1000
	var next_hit: int = 0
	while Time.get_ticks_msec() < end:
		d.heal()
		var best: Dictionary = {}
		for r: Dictionary in d.remotes():
			if String(r["name"]).begins_with("Cap") and int(r["kind"]) == NetProtocol.EntityKind.NPC:
				best = r
				break
		if not best.is_empty():
			var p: Vector3 = d.pos()
			var q: Vector3 = best["pos"]
			var dist: float = Vector2(q.x - p.x, q.z - p.z).length()
			d.look(d.yaw_to(p.x, p.z, q.x, q.z), 2.0)
			if dist > 2.3:
				d.hold(&"move_forward")
			else:
				d.release(&"move_forward")
				if Time.get_ticks_msec() >= next_hit:
					d.tap(&"primary_attack", 3)
					next_hit = Time.get_ticks_msec() + 450
		if Time.get_ticks_msec() >= next_shot and shots < 6:
			shots += 1
			next_shot = Time.get_ticks_msec() + 1800
			await d.shot("interfaz/barra_de_jefe_%02d.png" % shots, "pelea contra el Capitán del Vado con su barra de jefe (%d)" % shots, "cliente atacando al capitán")
		await d.frames(1)
	d.release_all()
	# Knocked down as seen from the HUD.
	await d.ensure_alive()
	d.cmd(NetProtocol.DEBUG_DOWN)
	await d.wait(1.5)
	await d.shot("interfaz/derribado_aviso.png", "jugador derribado (aviso de derribado y desangrado)", "comando de depuración 15")
	await d.wait(3.0)
	await d.shot("interfaz/derribado_aviso_2.png", "derribado unos segundos después", "comando de depuración 15")
	await d.ensure_alive()
