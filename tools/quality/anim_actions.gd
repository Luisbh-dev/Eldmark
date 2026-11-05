extends RefCounted
## Scripts of the animation strips of the capture bench (TEC-50): which actions are recorded and with which inputs.
##
## Used by [code]anim_strips.gd[/code], which builds the sandbox and plays them. It is kept apart, without touching the
## scene tree, so that it can be tested without a window that the scripts cover what they should (for example, that every NPC in the
## catalog has its set of strips).
## [br][br]
## An action is a [Dictionary] with [code]id[/code] (file name of the strip), [code]title[/code],
## [code]desc[/code], [code]tl[/code] (the input script, a [TL]) and [code]windows[/code] (the capture
## windows: each one yields one strip). The times of the scripts and of the windows are in physics ticks (60 per
## second) from the start of the script. Optional keys: [code]weapon[/code] and [code]alt_weapon[/code] (weapon
## ids from the catalog), [code]cam_y[/code], [code]target_y[/code] and [code]dist[/code] (close-up cameras).

## Frames of each strip.
const FRAMES: int = 12


## Script builder: stretches of held inputs ([method hold]), single presses
## ([method tap_at]) and events that in the game are imposed by the server ([method ev]).
class TL:
	var segs: Array = []
	var events: Array = []
	var cursor: int = 0

	## Holds [param move], [param buttons] and the camera ([param yaw0] to [param yaw1], in radians) for
	## [param ticks] ticks starting at the cursor.
	func hold(ticks: int, move: Vector2 = Vector2.ZERO, buttons: int = 0, yaw0: float = 0.0, yaw1: float = NAN) -> TL:
		segs.append({"a": cursor, "b": cursor + ticks, "move": move, "buttons": buttons,
				"yaw0": yaw0, "yaw1": yaw0 if is_nan(yaw1) else yaw1})
		cursor += ticks
		return self

	## Brief press of [param buttons] at tick [param at] ([param n] ticks), with [param move] and [param yaw].
	## It is inserted as its own stretch that takes precedence over the rest while it lasts.
	func tap_at(at: int, buttons: int, move: Vector2 = Vector2.ZERO, yaw: float = 0.0, n: int = 3) -> TL:
		segs.append({"a": at, "b": at + n, "move": move, "buttons": buttons, "yaw0": yaw, "yaw1": yaw, "over": true})
		return self

	## Event imposed at tick [param at] ([code]stagger[/code], [code]stun[/code], [code]death[/code],
	## [code]downed[/code], [code]revive[/code], [code]execute[/code] or [code]revived[/code]).
	func ev(at: int, kind: String, args: Dictionary = {}) -> TL:
		var e: Dictionary = args.duplicate()
		e["at"] = at
		e["kind"] = kind
		events.append(e)
		return self

	func duplicate_tl() -> TL:
		var t := TL.new()
		t.segs = segs.duplicate(true)
		t.events = events.duplicate(true)
		t.cursor = cursor
		return t


static func _win(window_name: String, from: int, to: int, cycle: bool = false, frames: int = FRAMES) -> Dictionary:
	return {"name": window_name, "from": from, "to": to, "cycle": cycle, "frames": frames}


## Window of one locomotion cycle: the executor waits [param warm] ticks, measures the animator's scale and
## records exactly one cycle.
static func _dyn(warm: int) -> Dictionary:
	return {"name": "ciclo", "dyn_warm": warm}


static func _act(id: String, title: String, desc: String, tl: TL, windows: Array, extra: Dictionary = {}) -> Dictionary:
	var a: Dictionary = {"id": id, "title": title, "desc": desc, "tl": tl, "windows": windows}
	a.merge(extra, true)
	return a


## Short names (without the [code]npc_[/code] prefix) of the NPC weapons in the catalog, without repeats and in
## catalog order: [code]hollow[/code], [code]captain[/code], [code]guard[/code], [code]guardian[/code]...
## Each one has its set of strips [code]npc_<name>_*[/code] ([method npc_actions]).
static func npc_profiles() -> Array[String]:
	var out: Array[String] = []
	for id: StringName in NpcCatalog.ids():
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		if definition == null:
			continue
		var short: String = String(definition.weapon_id).trim_prefix("npc_")
		if not out.has(short):
			out.append(short)
	return out


## Ids of all the actions in [param actions], to list or filter with [code]--only[/code].
static func ids_of(actions: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	for act: Dictionary in actions:
		out.append(String(act["id"]))
	return out


## Strips of the player character: locomotion, sword and shield combat, and bow.
static func player_actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var w_sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var w_bow: int = CombatCatalog.weapon_id(&"bow")
	var sword: WeaponTicks = CombatCatalog.weapon(w_sword)
	var bow: WeaponTicks = CombatCatalog.weapon(w_bow)
	var P: int = PlayerInput.PRIMARY
	var l1: AttackTicks = CombatCatalog.attack(sword.light_ids[0])
	var l2: AttackTicks = CombatCatalog.attack(sword.light_ids[1])
	var l3: AttackTicks = CombatCatalog.attack(sword.light_ids[2])
	var heavy: AttackTicks = CombatCatalog.attack(sword.heavy_id)

	# --- Locomotion ---------------------------------------------------------------------------
	var tl: TL = TL.new().hold(240)
	out.append(_act("loc_reposo", "Reposo (idle)", "Parado, 4 s.", tl, [_win("ciclo", 0, 236)]))

	tl = TL.new().hold(400, Vector2(0.0, 0.2))
	out.append(_act("loc_andar", "Andar (1 m/s)", "Un ciclo completo de andar.", tl, [_dyn(100)]))
	tl = TL.new().hold(400, Vector2(0.0, 1.0))
	out.append(_act("loc_trotar", "Trotar (5 m/s)", "Un ciclo completo de trote.", tl, [_dyn(80)]))
	tl = TL.new().hold(400, Vector2(0.0, 1.0), PlayerInput.SPRINT)
	out.append(_act("loc_esprintar", "Esprintar (7,5 m/s)", "Un ciclo completo de esprint.", tl, [_dyn(80)]))
	tl = TL.new().hold(400, Vector2(-1.0, 0.0))
	out.append(_act("loc_lateral_izquierda", "Moverse de lado a la izquierda", "Un ciclo de strafe a la izquierda (el modelo mira al frente de la cámara).", tl, [_dyn(80)]))
	tl = TL.new().hold(400, Vector2(1.0, 0.0))
	out.append(_act("loc_lateral_derecha", "Moverse de lado a la derecha", "Un ciclo de strafe a la derecha.", tl, [_dyn(80)]))
	tl = TL.new().hold(400, Vector2(0.0, -1.0))
	out.append(_act("loc_atras", "Moverse hacia atrás", "Un ciclo de retroceso (el modelo mira hacia delante).", tl, [_dyn(80)]))

	# Standing and running jump (takeoff at tick 30 / 40; rises 22 ticks, falls 22 ticks).
	tl = TL.new().hold(30).hold(6, Vector2.ZERO, PlayerInput.JUMP).hold(150)
	out.append(_act("loc_salto_parado", "Salto parado", "Subida, caída y aterrizaje de un salto sin carrera.", tl, [
			_win("subida", 28, 52), _win("caida", 52, 76), _win("aterrizaje", 74, 120), _win("completo", 26, 120)],
			{"cam_y": 1.9, "target_y": 1.8, "dist": 6.2}))
	tl = TL.new().hold(60, Vector2(0.0, 1.0)).hold(6, Vector2(0.0, 1.0), PlayerInput.JUMP).hold(150, Vector2(0.0, 1.0))
	out.append(_act("loc_salto_corriendo", "Salto corriendo", "Subida, caída y aterrizaje de un salto a 5 m/s.", tl, [
			_win("subida", 58, 82), _win("caida", 82, 106), _win("aterrizaje", 104, 150), _win("completo", 56, 150)],
			{"cam_y": 1.9, "target_y": 1.8, "dist": 6.5}))
	tl = TL.new().hold(70, Vector2(0.0, 1.0), PlayerInput.SPRINT).hold(6, Vector2(0.0, 1.0), PlayerInput.SPRINT | PlayerInput.JUMP).hold(150, Vector2(0.0, 1.0), PlayerInput.SPRINT)
	out.append(_act("loc_salto_esprintando", "Salto esprintando", "Salto a 7,5 m/s.", tl, [
			_win("completo", 66, 150, false, 12)], {"cam_y": 1.9, "target_y": 1.8, "dist": 7.0}))

	# Stopping dead.
	tl = TL.new().hold(90, Vector2(0.0, 1.0), PlayerInput.SPRINT).hold(120)
	out.append(_act("loc_parar_esprint", "Parar en seco desde el esprint", "Se suelta la tecla a 7,5 m/s.", tl, [_win("ciclo", 86, 146)], {"dist": 6.0}))
	tl = TL.new().hold(80, Vector2(0.0, 1.0)).hold(120)
	out.append(_act("loc_parar_trote", "Parar en seco desde el trote", "Se suelta la tecla a 5 m/s.", tl, [_win("ciclo", 76, 136)], {"dist": 6.0}))

	# Turns.
	tl = TL.new().hold(20).hold(70, Vector2.ZERO, 0, 0.0, PI).hold(60, Vector2.ZERO, 0, PI)
	out.append(_act("loc_giro_camara_parado", "Girar la cámara 180 grados estando parado", "El personaje no gira solo hasta que se mueve (la simulación manda); se ve lo que hace el cuerpo.", tl, [_win("ciclo", 10, 150)]))
	tl = TL.new().hold(20, Vector2.ZERO, 0, PI).hold(120, Vector2(0.0, 1.0), 0, PI)
	out.append(_act("loc_giro_al_arrancar", "Dar la vuelta al arrancar", "Parado mirando a -Z, la cámara ya mira a +Z y se pulsa W: el personaje gira 180 grados y echa a correr.", tl, [_win("ciclo", 16, 76)]))
	tl = TL.new().hold(70, Vector2(0.0, 1.0)).hold(40, Vector2(0.0, 1.0), 0, 0.0, PI).hold(100, Vector2(0.0, 1.0), 0, PI)
	out.append(_act("loc_giro_en_carrera", "Giro de 180 grados corriendo", "Corriendo hacia delante la cámara gira 180 grados en 40 ticks.", tl, [_win("ciclo", 66, 150)], {"dist": 6.0}))

	# --- Combat: sword and shield ------------------------------------------------------------
	var s1: int = 10
	tl = TL.new().hold(10).hold(3, Vector2.ZERO, P).hold(l1.total_ticks + 60)
	out.append(_act("com_ligero_1", "Golpe ligero 1", "Primer golpe del combo ligero (clic izquierdo corto).", tl, [_win("ciclo", s1 - 4, s1 + l1.total_ticks + 6)]))
	var s2: int = s1 + l1.total_ticks
	var press2: int = s1 + l1.combo_window_from() + ceili(float(l1.combo_window_ticks) / 3.0)
	tl = TL.new().hold(s2 + l2.total_ticks + 90)
	tl.tap_at(s1, P).tap_at(press2, P)
	out.append(_act("com_ligero_2", "Golpe ligero 2", "Segundo golpe del combo: se pulsa dentro de la ventana de enlace del primero.", tl, [_win("ciclo", s2 - 6, s2 + l2.total_ticks + 6)]))
	var s3: int = s2 + l2.total_ticks
	var press3: int = s2 + l2.combo_window_from() + ceili(float(l2.combo_window_ticks) / 3.0)
	tl = TL.new().hold(s3 + l3.total_ticks + 90)
	tl.tap_at(s1, P).tap_at(press2, P).tap_at(press3, P)
	out.append(_act("com_ligero_3", "Golpe ligero 3", "Tercer golpe del combo.", tl, [_win("ciclo", s3 - 6, s3 + l3.total_ticks + 6)]))
	out.append(_act("com_combo_completo", "Combo ligero completo (1-2-3)", "Los tres golpes seguidos, una sola rejilla.", tl.duplicate_tl(), [_win("ciclo", s1 - 4, s3 + l3.total_ticks + 6)]))

	# Charged heavy attack.
	var hold_ticks: int = heavy.charge_min_ticks + 12
	tl = TL.new().hold(10).hold(hold_ticks, Vector2.ZERO, P).hold(heavy.total_ticks + 90)
	out.append(_act("com_fuerte", "Golpe fuerte: carga y golpe", "Se mantiene el botón: carga y, al soltarlo, el fuerte.", tl, [
			_win("carga", 8, 10 + hold_ticks), _win("golpe", 10 + hold_ticks - 4, 10 + hold_ticks + heavy.total_ticks + 6)]))
	# Heavy attack with a long charge.
	var long_hold: int = maxi(heavy.charge_max_ticks + 8, hold_ticks + 20)
	tl = TL.new().hold(10).hold(long_hold, Vector2.ZERO, P).hold(heavy.total_ticks + 90)
	out.append(_act("com_fuerte_carga_maxima", "Golpe fuerte con carga máxima", "Botón mantenido hasta pasar la carga máxima.", tl, [
			_win("carga", 8, 10 + long_hold), _win("golpe", 10 + long_hold - 4, 10 + long_hold + heavy.total_ticks + 6)]))

	# Block.
	tl = TL.new().hold(20).hold(90, Vector2.ZERO, PlayerInput.BLOCK).hold(80)
	out.append(_act("com_bloqueo", "Bloqueo con el escudo", "Entrar, mantener y salir del bloqueo (clic derecho).", tl, [
			_win("entrar", 18, 46), _win("mantener", 46, 108), _win("salir", 108, 150)]))
	tl = TL.new().hold(20).hold(110, Vector2(0.0, 1.0), PlayerInput.BLOCK).hold(80)
	out.append(_act("com_bloqueo_andando", "Bloqueo andando", "Bloqueo mientras se avanza (a escala de movimiento reducida).", tl, [_win("ciclo", 40, 130)]))

	# Dodges.
	var dd: int = sword.dodge.duration_ticks
	var dodge_dirs: Array = [["delante", Vector2(0.0, 1.0)], ["atras", Vector2(0.0, -1.0)],
			["izquierda", Vector2(-1.0, 0.0)], ["derecha", Vector2(1.0, 0.0)], ["sin_direccion", Vector2.ZERO]]
	for d: Array in dodge_dirs:
		tl = TL.new().hold(dd + 100)
		tl.tap_at(20, PlayerInput.DODGE, d[1])
		out.append(_act("com_esquiva_" + String(d[0]), "Esquiva " + String(d[0]).replace("_", " "), "Ctrl con la dirección indicada (%d ticks)." % dd, tl, [_win("ciclo", 16, 20 + dd + 18)], {"dist": 6.0}))

	# Taking a hit, stun, death (the states that in the game are imposed by the server).
	tl = TL.new().hold(120)
	tl.ev(30, "stagger", {"ticks": 24, "kb": Vector2(0.0, 3.0)})
	out.append(_act("com_recibir_golpe", "Recibir un golpe (tambaleo)", "Impuesto como lo haría el servidor: 24 ticks, empuje hacia atrás.", tl, [_win("ciclo", 26, 100)]))
	tl = TL.new().hold(60, Vector2(0.0, 1.0)).hold(120)
	tl.ev(40, "stagger", {"ticks": 24, "kb": Vector2(0.0, 3.0)})
	out.append(_act("com_recibir_golpe_corriendo", "Recibir un golpe corriendo", "Tambaleo mientras se corre.", tl, [_win("ciclo", 36, 110)]))
	tl = TL.new().hold(120)
	tl.ev(30, "hit", {"amount": 90.0})
	out.append(_act("com_golpe_ligero_sin_control", "Recibir un golpe ligero sin tambaleo", "Un golpe con daño que no impone control (los ligeros 1 y 2 tienen stagger 0): solo la reacción del cuerpo (ART-50).", tl, [_win("ciclo", 24, 70)]))
	tl = TL.new().hold(20).hold(130, Vector2.ZERO, PlayerInput.BLOCK).hold(60)
	tl.ev(60, "block_hit", {"amount": 0.0}).ev(100, "block_hit", {"amount": 0.0})
	out.append(_act("com_bloqueo_golpe_bloqueado", "Golpe bloqueado con el escudo", "Dos golpes bloqueados del todo (daño 0): empujón del brazo del escudo y la columna (ART-48).", tl, [_win("ciclo", 52, 128)]))
	tl = TL.new().hold(200)
	tl.ev(30, "stun", {"ticks": 100})
	out.append(_act("com_aturdimiento", "Aturdimiento", "Control de 100 ticks.", tl, [_win("ciclo", 26, 160)]))
	tl = TL.new().hold(260)
	tl.ev(30, "death")
	out.append(_act("com_muerte", "Muerte", "Caída y cadáver, 3,5 s.", tl, [_win("ciclo", 26, 236)]))
	tl = TL.new().hold(60, Vector2(0.0, 1.0)).hold(220)
	tl.ev(40, "death")
	out.append(_act("com_muerte_corriendo", "Muerte corriendo", "Muere a 5 m/s.", tl, [_win("ciclo", 36, 220)], {"dist": 6.0}))
	tl = TL.new().hold(260)
	tl.ev(30, "downed")
	out.append(_act("com_derribado", "Derribado (caído, vivo)", "Pasa a DOWNED y se queda en el suelo.", tl, [_win("ciclo", 26, 220)]))
	tl = TL.new().hold(30).hold(180, Vector2(0.0, 1.0))
	tl.ev(20, "downed")
	out.append(_act("com_derribado_arrastrandose", "Derribado arrastrándose", "DOWNED y se mueve hacia delante.", tl, [_win("ciclo", 60, 200)]))
	var rv: CombatTables = CombatCatalog.tables()
	# The helper: REVIVE action (INTERACT held).
	tl = TL.new().hold(20).hold(rv.revive_ticks + 2, Vector2.ZERO, PlayerInput.INTERACT).hold(150)
	tl.ev(20, "revive").ev(20 + rv.revive_ticks, "revived")
	out.append(_act("com_reanimando", "Reanimar a un compañero (el que ayuda)", "Acción REVIVE durante %d ticks, con INTERACT mantenido." % rv.revive_ticks, tl, [_win("ciclo", 16, 20 + rv.revive_ticks + 16)]))
	# The downed one: goes to DOWNED and the server gets them up (get_up).
	tl = TL.new().hold(300)
	tl.ev(10, "downed").ev(90, "revived")
	out.append(_act("com_levantarse_reanimado", "Levantarse tras ser reanimado", "DOWNED durante 80 ticks y levantado por el servidor (clip get_up).", tl, [_win("ciclo", 84, 84 + 130)]))
	tl = TL.new().hold(20).hold(rv.execute_ticks + 4, Vector2.ZERO, PlayerInput.INTERACT).hold(100)
	tl.ev(20, "execute")
	out.append(_act("com_remate", "Rematar a un derribado", "El que remata: acción EXECUTE.", tl, [_win("ciclo", 16, 20 + rv.execute_ticks + 14)]))

	# Abilities 1-3 (sword and shield).
	var ab_buttons: Array[int] = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3]
	for i: int in 3:
		var ab: AbilityTicks = CombatCatalog.ability(sword.ability_id(i))
		var hold_len: int = 3
		if ab.channel and ab.channel_hold:
			hold_len = ab.total_ticks
		tl = TL.new().hold(20).hold(hold_len, Vector2.ZERO, ab_buttons[i]).hold(ab.total_ticks + 90)
		out.append(_act("com_habilidad_%d_%s" % [i + 1, String(ab.name)], "Habilidad %d: %s" % [i + 1, String(ab.name)], "Tecla %d con espada y escudo (%d ticks)." % [i + 1, ab.total_ticks], tl, [_win("ciclo", 16, 20 + ab.total_ticks + 14)], {"dist": 6.0}))
	# Potions.
	var consumables: PackedInt32Array = CombatCatalog.consumable_ids()
	if not consumables.is_empty():
		var potion: AbilityTicks = CombatCatalog.ability(consumables[0])
		tl = TL.new().hold(20).hold(3, Vector2.ZERO, PlayerInput.CONSUMABLE_1).hold(potion.total_ticks + 90)
		out.append(_act("com_pocion", "Beber una poción", "Tecla R (%d ticks)." % potion.total_ticks, tl, [_win("ciclo", 16, 20 + potion.total_ticks + 14)]))
	# Weapon swap.
	tl = TL.new().hold(20).hold(3, Vector2.ZERO, PlayerInput.SWAP_WEAPON).hold(160)
	out.append(_act("com_cambiar_arma", "Cambiar de arma (Q)", "De espada y escudo a arco.", tl, [_win("ciclo", 16, 100)], {"alt_weapon": w_bow}))

	# --- Bow ----------------------------------------------------------------------------------
	var bq: AttackTicks = CombatCatalog.attack(bow.light_ids[0])
	var bh: AttackTicks = CombatCatalog.attack(bow.heavy_id)
	tl = TL.new().hold(10).hold(3, Vector2.ZERO, P).hold(bq.total_ticks + 80)
	out.append(_act("arc_ligero", "Arco: disparo rápido", "Clic corto con el arco.", tl, [_win("ciclo", 6, 10 + bq.total_ticks + 10)], {"weapon": w_bow}))
	var bhold: int = bh.charge_min_ticks + 14
	tl = TL.new().hold(10).hold(bhold, Vector2.ZERO, P).hold(bh.total_ticks + 90)
	out.append(_act("arc_cargado", "Arco: tensar y soltar", "Botón mantenido y soltado.", tl, [
			_win("tensar", 8, 10 + bhold), _win("soltar", 10 + bhold - 4, 10 + bhold + bh.total_ticks + 8)], {"weapon": w_bow}))
	for i: int in 3:
		var bab: AbilityTicks = CombatCatalog.ability(bow.ability_id(i))
		tl = TL.new().hold(20).hold(3, Vector2.ZERO, ab_buttons[i]).hold(bab.total_ticks + 90)
		out.append(_act("arc_habilidad_%d_%s" % [i + 1, String(bab.name)], "Arco, habilidad %d: %s" % [i + 1, String(bab.name)], "Tecla %d con el arco." % (i + 1), tl, [_win("ciclo", 16, 20 + bab.total_ticks + 14)], {"weapon": w_bow, "dist": 6.0}))
	tl = TL.new().hold(400, Vector2(0.0, 1.0))
	out.append(_act("arc_trotar", "Arco: trotar", "Locomoción con el arco en la mano.", tl, [_dyn(80)], {"weapon": w_bow}))
	return out


## NPC strips in the sandbox: every NPC weapon in the catalog (Hollow, Captain, realm guard, Gate
## Guardian) with its idle, walk, sprint, light attack, heavy attack, block, stagger and death. They wear the
## player's look (NPCs do not have their own model yet) but the weapon, the ticks and the clip set are
## the NPC's.
static func npc_actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var P: int = PlayerInput.PRIMARY
	for npc: String in npc_profiles():
		var wid: int = CombatCatalog.weapon_id(StringName("npc_" + npc))
		if wid <= 0:
			continue
		var w: WeaponTicks = CombatCatalog.weapon(wid)
		var light: AttackTicks = CombatCatalog.attack(w.light_ids[0])
		var heavy: AttackTicks = CombatCatalog.attack(w.heavy_id)
		var tl: TL = TL.new().hold(240)
		out.append(_act("npc_%s_reposo" % npc, "PNJ %s: reposo" % npc, "Parado con el arma de PNJ.", tl, [_win("ciclo", 0, 236)], {"weapon": wid}))
		tl = TL.new().hold(400, Vector2(0.0, 1.0))
		out.append(_act("npc_%s_andar" % npc, "PNJ %s: andar/trotar" % npc, "Los PNJ se mueven con la misma simulación del jugador (5 m/s al correr).", tl, [_dyn(80)], {"weapon": wid}))
		tl = TL.new().hold(400, Vector2(0.0, 1.0), PlayerInput.SPRINT)
		out.append(_act("npc_%s_esprintar" % npc, "PNJ %s: esprintar" % npc, "Esprint.", tl, [_dyn(80)], {"weapon": wid}))
		tl = TL.new().hold(10).hold(3, Vector2.ZERO, P).hold(light.total_ticks + 100)
		out.append(_act("npc_%s_ataque_ligero" % npc, "PNJ %s: ataque ligero" % npc, "Ataque ligero (%s, %d ticks)." % [String(light.name), light.total_ticks], tl, [_win("ciclo", 6, 10 + light.total_ticks + 10)], {"weapon": wid}))
		var hh: int = heavy.charge_min_ticks + 10
		tl = TL.new().hold(10).hold(hh, Vector2.ZERO, P).hold(heavy.total_ticks + 90)
		out.append(_act("npc_%s_ataque_fuerte" % npc, "PNJ %s: ataque fuerte" % npc, "Ataque fuerte (%s, %d ticks)." % [String(heavy.name), heavy.total_ticks], tl, [_win("ciclo", 6, 10 + hh + heavy.total_ticks + 10)], {"weapon": wid}))
		tl = TL.new().hold(20).hold(90, Vector2.ZERO, PlayerInput.BLOCK).hold(80)
		out.append(_act("npc_%s_bloqueo" % npc, "PNJ %s: bloqueo" % npc, "Entrar, mantener y salir del bloqueo (los guardias lo usan; el resto lo tiene en sus datos).", tl, [_win("ciclo", 18, 150)], {"weapon": wid}))
		tl = TL.new().hold(260)
		tl.ev(30, "stagger", {"ticks": 30, "kb": Vector2(0.0, 3.0)})
		out.append(_act("npc_%s_recibir_golpe" % npc, "PNJ %s: recibir golpe" % npc, "Tambaleo.", tl, [_win("ciclo", 26, 100)], {"weapon": wid}))
		tl = TL.new().hold(260)
		tl.ev(30, "death")
		out.append(_act("npc_%s_muerte" % npc, "PNJ %s: morir" % npc, "Muerte.", tl, [_win("ciclo", 26, 236)], {"weapon": wid}))
	return out
