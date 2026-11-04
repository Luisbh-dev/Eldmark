extends RefCounted
## Quality capture bench (TEC-50), interfaz area (scenario of online_driver.gd).
##
## Networked client interface: loading screen, HUD at rest and in a fight, nameplates, settings, inventory,
## character, chat, scoreboard, social menu, death and respawn choice, fort capture and boss.

var d: Variant


func run(drv: Variant) -> void:
	d = drv
	await _loading()
	if not await d.enter_world():
		return
	await d.wait(2.5)
	await d.shot("interfaz/hud_reposo_campamento.png", "HUD en reposo en el punto de aparición del campamento (con aliados cerca)",
			"online_driver + sc_interfaz: sin tocar nada tras entrar")
	await _nameplates()
	await _windows()
	await d.ensure_alive()
	await _fort_capture()
	await d.ensure_alive()
	await _fight_hud()
	await d.ensure_alive()
	await _death()


func _loading() -> void:
	# Captures of the loading screen while it connects and loads the zone.
	var n: int = 0
	var end: int = Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < end and n < 14:
		await d.frames(6)
		var client: Variant = d.main.get_client()
		if client != null and client.get_state() == NetClient.State.IN_WORLD and d.main.get_hud() != null:
			break
		n += 1
		await d.shot("interfaz/carga_%02d.png" % n, "pantalla de carga (conectando / cargando la zona), captura %d" % n,
				"capturas cada ~0,2 s mientras el cliente conecta")
		await d.wait(0.15)


func _nameplates() -> void:
	d.heal()
	# Allies near the camp: look at the nearest one from my realm.
	var my_realm: int = d.client.get_config().realm
	var target: Dictionary = {}
	for r: Dictionary in d.remotes():
		if int(r["realm"]) == my_realm and int(r["kind"]) == NetProtocol.EntityKind.PLAYER:
			target = r
			break
	if target.is_empty():
		d.note("sin aliados cerca del campamento para las placas de nombre")
	else:
		var p: Vector3 = d.pos()
		var q: Vector3 = target["pos"]
		d.look(d.yaw_to(p.x, p.z, q.x, q.z), 3.0)
		await d.wait(0.8)
		await d.shot("interfaz/placas_de_nombre_aliados.png", "placa de nombre de un aliado (%s) en el campamento" % target["name"],
				"mirando al aliado más cercano")


func _windows() -> void:
	await d.tp(0.0, -134.0, 180.0, 4.0, NAN, 1.0)
	# Scoreboard (Tab).
	Input.action_press(&"scoreboard")
	await d.wait(0.7)
	await d.shot("interfaz/marcador_tab.png", "marcador de la zona (Tab mantenido)", "Input.action_press(scoreboard)")
	Input.action_release(&"scoreboard")
	await d.wait(0.3)
	# Chat: open, type and send several lines.
	var chat: Variant = d.hud.get_chat()
	if chat != null:
		chat.open()
		await d.wait(0.4)
		chat.get_input().text = "Hola, Vado Gris. Probando el chat de zona..."
		await d.wait(0.2)
		await d.shot("interfaz/chat_abierto_escribiendo.png", "línea de chat abierta con texto escrito", "hud.get_chat().open() y texto en la línea")
		chat.submit("Primera línea de prueba")
		chat.open()
		await d.wait(0.2)
		chat.submit("/g ¿alguien ve el fuerte?")
		chat.open()
		await d.wait(0.2)
		chat.submit("/ayuda")
		await d.wait(0.6)
		await d.shot("interfaz/chat_con_mensajes.png", "chat con varias líneas enviadas (incluida una orden)", "chat.submit(...) tres veces")
		chat.close()
	# Inventory and character: given items, gold, level and XP with the debug commands.
	var db: ItemDatabase = ItemDatabase.shared()
	for id: StringName in [&"potion_health", &"potion_stamina", &"sword_shield_vado", &"bow_vado"]:
		var nid: int = db.net_id_of(id)
		if nid > 0:
			d.cmd(NetProtocol.DEBUG_ITEM_GIVE, NetMessages.DebugCommand.item_give(nid, 3 if String(id).begins_with("potion") else 1).payload)
	d.cmd(NetProtocol.DEBUG_CURRENCY_ADD, NetMessages.DebugCommand.currency_add(Currency.Code.GOLD, 275).payload)
	d.cmd(NetProtocol.DEBUG_LEVEL_SET, PackedByteArray([7]))
	d.cmd(NetProtocol.DEBUG_XP_ADD, PackedByteArray([0x10, 0x27, 0, 0]))
	await d.wait(1.2)
	await d.key(KEY_I)
	await d.wait(0.7)
	await d.shot("interfaz/inventario_i.png", "inventario (I) tras darse pociones, armas y oro por comandos de depuración", "tecla I")
	await d.key(KEY_I)
	await d.wait(0.3)
	await d.key(KEY_C)
	await d.wait(0.7)
	await d.shot("interfaz/personaje_c.png", "ventana de personaje (C)", "tecla C")
	await d.key(KEY_C)
	await d.wait(0.3)
	# Social menu on an ally.
	var my_realm: int = d.client.get_config().realm
	var ally: Object = null
	for r: Dictionary in d.remotes():
		if int(r["realm"]) == my_realm and int(r["kind"]) == NetProtocol.EntityKind.PLAYER:
			ally = r["view"]
			break
	var social: Variant = d.hud.get_social_menu()
	if ally != null and social != null:
		social.open_for(ally)
		await d.wait(0.6)
		await d.shot("interfaz/menu_social_g.png", "menú social sobre un aliado (invitar al grupo, susurrar)", "SocialMenu.open_for(vista del aliado)")
		await d.key(KEY_ESCAPE)
		await d.wait(0.3)
	else:
		d.note("no se encontró un aliado para abrir el menú social")
	# F10 settings, one capture per tab.
	await d.key(KEY_F10)
	await d.wait(0.8)
	var menu: Node = _find_class(d.root, &"SettingsMenu")
	if menu == null:
		await d.shot("interfaz/ajustes_f10.png", "ajustes (F10); no se encontró el nodo de pestañas", "tecla F10")
		d.note("no se encontró SettingsMenu en el árbol")
	else:
		var tabs: TabContainer = menu.get_tabs()
		for i: int in tabs.get_tab_count():
			tabs.current_tab = i
			await d.wait(0.5)
			var title: String = tabs.get_tab_title(i)
			await d.shot("interfaz/ajustes_f10_%d_%s.png" % [i + 1, title.to_lower().replace(" ", "_").replace("á", "a").replace("í", "i").replace("é", "e").replace("ó", "o")],
					"ajustes (F10), pestaña «%s»" % title, "tecla F10 y cambio de pestaña")
	await d.key(KEY_F10)
	await d.wait(0.4)
	# Hint bar and debug panel (F3).
	await d.key(KEY_F3)
	await d.wait(0.6)
	await d.shot("interfaz/panel_depuracion_f3.png", "panel de depuración (F3)", "tecla F3")
	await d.key(KEY_F3)


func _fort_capture() -> void:
	# Fort: the captain is killed and the quick capture is set; the player waits inside the circle.
	await d.tp(-30.0, 0.0, -90.0, 6.0, NAN, 0.8)
	await d.wait_healing(1.0)
	await d.shot("interfaz/placas_de_nombre_fuerte.png", "placas de nombre de PNJ y jugadores cerca de la puerta del fuerte",
			"teletransporte de depuración a 30 m de la puerta")
	await d.tp(-8.5, 0.0, -90.0, 6.0, NAN, 0.8)
	d.heal()
	d.cmd(NetProtocol.DEBUG_FORT_KILL_CAPTAIN)
	d.cmd(NetProtocol.DEBUG_FORT_CAPTURE_SPEED, PackedByteArray([6]))
	for i: int in 8:
		await d.wait_healing(1.2)
		await d.shot("interfaz/captura_fuerte_%02d.png" % (i + 1), "dentro del círculo de captura del fuerte (secuencia %d)" % (i + 1),
				"teletransporte al círculo, capitán muerto con el comando 10 y captura x6 (comando 11)")
	# Boss bar: the Ford Captain respawns when the fort is reset.
	d.cmd(NetProtocol.DEBUG_FORT_RESET)
	await d.wait_healing(3.0)


func _fight_hud() -> void:
	# Fight against the Hollow and the courtyard captain with the HUD visible.
	await d.tp(-12.0, -6.0, -60.0, 4.0, NAN, 1.0)
	var end: int = Time.get_ticks_msec() + 22000
	var next_shot: int = Time.get_ticks_msec() + 1500
	var shots: int = 0
	var next_hit: int = 0
	var next_heal: int = 0
	while Time.get_ticks_msec() < end:
		var enemy: Dictionary = d.nearest_enemy(40.0)
		if not enemy.is_empty():
			var p: Vector3 = d.pos()
			var q: Vector3 = enemy["pos"]
			var dist: float = Vector2(q.x - p.x, q.z - p.z).length()
			d.look(d.yaw_to(p.x, p.z, q.x, q.z), 2.0)
			if dist > 2.3:
				d.hold(&"move_forward")
			else:
				d.release(&"move_forward")
				if Time.get_ticks_msec() >= next_hit:
					d.tap(&"primary_attack", 3)
					next_hit = Time.get_ticks_msec() + 450
		if Time.get_ticks_msec() >= next_shot and shots < 10:
			shots += 1
			next_shot = Time.get_ticks_msec() + 1700
			await d.shot("interfaz/hud_en_pelea_%02d.png" % shots, "HUD en plena pelea contra los PNJ del fuerte (%d)" % shots,
					"cliente combatiendo solo con Input.action_press: acercarse y atacar")
		if Time.get_ticks_msec() >= next_heal:
			d.heal()
			next_heal = Time.get_ticks_msec() + 300
		await d.frames(1)
	d.release_all()


func _death() -> void:
	await d.tp(-30.0, 0.0, -90.0, 8.0, NAN, 1.0)
	d.cmd(NetProtocol.DEBUG_KILL)
	await d.wait(2.8)
	await d.shot("interfaz/pantalla_de_muerte.png", "pantalla de muerte con la cuenta atrás y los puntos de reaparición", "comando de depuración 3 (matar)")
	var map: Variant = d.hud.get_world_map()
	if map != null:
		map.open(true)
		await d.wait(0.8)
		await d.shot("interfaz/mapa_eleccion_de_reaparicion.png", "mapa en modo elegir dónde reaparecer", "WorldMap.open(true) con el jugador muerto")
		map.close()
		await d.wait(0.3)
	# Wait until respawning is possible and request it.
	var end: int = Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < end and d.client.is_dead():
		var respawn_tick: int = d.client.get_respawn_tick()
		if respawn_tick > 0 and d.client.get_estimated_server_tick() >= respawn_tick:
			d.client.send_respawn_request(0)
			await d.wait(1.0)
		await d.wait(0.5)
	await d.wait(1.5)
	await d.shot("interfaz/tras_reaparecer.png", "justo después de reaparecer", "tras la elección de reaparición")


func _find_class(node: Node, global_name: StringName) -> Node:
	var script: Script = node.get_script() as Script
	if script != null and script.get_global_name() == global_name:
		return node
	for child: Node in node.get_children():
		var found: Node = _find_class(child, global_name)
		if found != null:
			return found
	return null
