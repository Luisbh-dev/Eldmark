extends TestCase
## Pruebas del banco de capturas de calidad (TEC-50, [code]tools/quality/[/code]).
## [br][br]
## El banco necesita ventana y GPU, así que aquí solo se prueba lo que se puede sin ellas: que todos sus scripts se cargan (un
## error de sintaxis se descubre aquí y no tras media hora de capturas), que los guiones de las tiras cubren lo que dice el plan de
## calidad (cada PNJ del catálogo tiene su juego de tiras; guardias y Guardianes también), que las tiras de personajes vistos desde otro
## cliente tienen ids sin repetir y condiciones bien formadas, la lógica pura de la grabadora (el anillo de fotogramas, la validación de
## las tomas y el [code]meta.json[/code] con el clip de la capa de animación) y las piezas de Python (juntar tiras, índice, orden) con
## datos de mentira, si hay Python y Pillow en la máquina.

const QUALITY_DIR: String = "res://tools/quality"
const AnimActions = preload("res://tools/quality/anim_actions.gd")
const Recorder = preload("res://tools/quality/strip_recorder.gd")
const Specs = preload("res://tools/quality/strip_specs.gd")
const ScBot = preload("res://tools/quality/sc_remotos_bot.gd")
const ScPnj = preload("res://tools/quality/sc_remotos_pnj.gd")
const ScBlock = preload("res://tools/quality/sc_bloqueo.gd")

## Tiras que tiene que haber de cada PNJ en el sandbox.
const NPC_STRIPS: Array[String] = ["reposo", "andar", "esprintar", "ataque_ligero", "ataque_fuerte", "bloqueo",
		"recibir_golpe", "muerte"]
## Claves de objetivo que entienden los escenarios de remotos.
const TARGET_KEYS: Array[String] = ["bot", "hueco", "capitan", "guardia", "guardian", "local"]
const SCRATCH_DIR: String = "res://build/test_quality_tools"


# --- Humo ------------------------------------------------------------------------------------

func test_every_quality_script_loads() -> void:
	var dir: DirAccess = DirAccess.open(QUALITY_DIR)
	if not assert_not_null(dir, "existe %s" % QUALITY_DIR):
		return
	var count: int = 0
	for file: String in dir.get_files():
		if not file.ends_with(".gd"):
			continue
		var path: String = QUALITY_DIR.path_join(file)
		var script: GDScript = load(path) as GDScript
		if assert_not_null(script, "%s se carga (un error de sintaxis lo dejaría en null)" % path):
			assert_true(script.can_instantiate(), "%s se puede instanciar" % path)
		count += 1
	assert_true(count >= 12, "el banco tiene sus scripts (%d)" % count)


func test_command_line_tools_have_their_entry_point() -> void:
	for file: String in ["anim_strips.gd", "online_driver.gd"]:
		var script: GDScript = load(QUALITY_DIR.path_join(file)) as GDScript
		if not assert_not_null(script):
			continue
		assert_true(script.get_script_method_list().any(
				func(method: Dictionary) -> bool: return method["name"] == "_initialize"),
				"%s es un script de línea de comandos (SceneTree._initialize)" % file)
	for file: String in ["sc_combate.gd", "sc_mapa.gd", "sc_mundo.gd", "sc_interfaz.gd", "sc_extras.gd", "sc_front.gd",
			"sc_gallery.gd", "sc_realm.gd", "sc_remotos_bot.gd", "sc_remotos_pnj.gd", "sc_bloqueo.gd", "sc_video.gd"]:
		var script: GDScript = load(QUALITY_DIR.path_join(file)) as GDScript
		if not assert_not_null(script):
			continue
		assert_true(script.get_script_method_list().any(
				func(method: Dictionary) -> bool: return method["name"] == "run"),
				"%s es un escenario del conductor (func run(d))" % file)


# --- Guiones de las tiras del sandbox ---------------------------------------------------------

func test_npc_profiles_cover_every_npc_weapon_of_the_catalog() -> void:
	var profiles: Array[String] = AnimActions.npc_profiles()
	var expected: Dictionary = {}
	for id: StringName in NpcCatalog.ids():
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		expected[String(definition.weapon_id).trim_prefix("npc_")] = true
	assert_eq(profiles.size(), expected.size(), "un perfil por arma de PNJ distinta del catálogo")
	for short: String in expected.keys():
		assert_true(profiles.has(short), "el perfil %s tiene tiras" % short)
	# Los cuatro que pide el plan de calidad: Hueco, Capitán, guardias y Guardianes de la Puerta.
	for short: String in ["hollow", "captain", "guard", "guardian"]:
		assert_true(profiles.has(short), "hay tiras de %s" % short)


func test_every_npc_weapon_has_a_complete_set_of_strips() -> void:
	var ids: PackedStringArray = AnimActions.ids_of(AnimActions.npc_actions())
	for short: String in AnimActions.npc_profiles():
		assert_true(CombatCatalog.weapon_id(StringName("npc_" + short)) > 0, "npc_%s existe en el catálogo de combate" % short)
		for strip: String in NPC_STRIPS:
			assert_true(ids.has("npc_%s_%s" % [short, strip]), "falta la tira npc_%s_%s" % [short, strip])


func test_every_weapon_in_data_combat_with_the_npc_prefix_has_a_profile() -> void:
	var dir: DirAccess = DirAccess.open("res://data/combat")
	if not assert_not_null(dir):
		return
	var profiles: Array[String] = AnimActions.npc_profiles()
	for file: String in dir.get_files():
		if not file.begins_with("npc_") or file.begins_with("npc_shape_") or not file.ends_with(".tres"):
			continue
		var resource: Resource = load("res://data/combat/" + file)
		if resource is WeaponDefinition:
			var short: String = String((resource as WeaponDefinition).id).trim_prefix("npc_")
			assert_true(profiles.has(short), "el arma %s tiene tiras de PNJ (la usa un PNJ del catálogo)" % file)


func test_strip_ids_are_unique_and_windows_fit_inside_their_scripts() -> void:
	var seen: Dictionary = {}
	var all: Array[Dictionary] = []
	all.append_array(AnimActions.player_actions())
	all.append_array(AnimActions.npc_actions())
	assert_true(all.size() > 60, "hay un buen puñado de acciones (%d)" % all.size())
	for act: Dictionary in all:
		var id: String = String(act["id"])
		assert_false(seen.has(id), "id repetido: %s" % id)
		seen[id] = true
		var tl: AnimActions.TL = act["tl"] as AnimActions.TL
		var end: int = 0
		for seg: Dictionary in tl.segs:
			end = maxi(end, int(seg["b"]))
		assert_true(not (act["windows"] as Array).is_empty(), "%s tiene ventanas" % id)
		for win: Dictionary in act["windows"]:
			if win.has("dyn_warm"):
				assert_true(int(win["dyn_warm"]) + 200 <= end, "%s: el guion cubre el ciclo de locomoción" % id)
				continue
			assert_true(int(win["from"]) < int(win["to"]), "%s [%s]: la ventana avanza" % [id, win["name"]])
			assert_true(int(win["to"]) <= end, "%s [%s]: el guion dura más que la ventana (%d <= %d)" % [id, win["name"], win["to"], end])
			assert_true(int(win["frames"]) >= 2, "%s [%s]: al menos dos fotogramas" % [id, win["name"]])


func test_player_strips_cover_what_the_quality_plan_asks_for() -> void:
	var ids: PackedStringArray = AnimActions.ids_of(AnimActions.player_actions())
	for id: String in ["loc_reposo", "loc_andar", "loc_trotar", "loc_esprintar", "loc_lateral_izquierda", "loc_lateral_derecha",
			"loc_atras", "com_ligero_1", "com_ligero_2", "com_ligero_3", "com_combo_completo", "com_fuerte", "com_bloqueo",
			"com_bloqueo_andando", "com_esquiva_delante", "com_esquiva_atras", "com_esquiva_izquierda", "com_esquiva_derecha",
			"com_recibir_golpe", "com_muerte", "com_muerte_corriendo", "com_derribado", "arc_ligero", "arc_cargado"]:
		assert_true(ids.has(id), "falta la tira %s del listón de animación" % id)


# --- Tiras de personajes vistos desde otro cliente ---------------------------------------------

func _specs_of(script: GDScript) -> Specs:
	var scenario: RefCounted = script.new()
	var specs: Specs = Specs.new(null, null)
	scenario.set("specs", specs)
	scenario.call("_define_specs")
	return specs


func test_remote_strip_specs_are_well_formed() -> void:
	var seen: Dictionary = {}
	for script: GDScript in [ScBot, ScPnj]:
		var specs: Specs = _specs_of(script)
		assert_true(specs.specs.size() >= 9, "el escenario define sus tiras")
		for spec: Dictionary in specs.specs:
			var id: String = String(spec["id"])
			assert_true(id.begins_with("rem_"), "%s empieza por rem_ (va a las carpetas remoto y remoto_lado)" % id)
			assert_false(seen.has(id), "id repetido entre escenarios: %s" % id)
			seen[id] = true
			assert_true(TARGET_KEYS.has(String(spec["target"])), "%s: objetivo conocido (%s)" % [id, spec["target"]])
			assert_true((spec["cond"] as Callable).is_valid(), "%s tiene condición" % id)
			assert_true(int(spec["n"]) == 12, "%s: 12 fotogramas, como las demás tiras" % id)
			assert_true(int(spec["interval"]) >= Recorder.SAMPLE_MS, "%s: el intervalo no baja de la cadencia de la grabadora" % id)
			assert_true(int(spec["pre"]) >= 0, "%s: lleva el principio de la acción" % id)


func test_remote_strips_include_guards_and_gate_guardians() -> void:
	var ids: PackedStringArray = PackedStringArray()
	for spec: Dictionary in _specs_of(ScPnj).specs:
		ids.append(String(spec["id"]))
	for id: String in ["rem_hueco_ataque", "rem_hueco_muerte", "rem_capitan_ataque", "rem_capitan_muerte", "rem_guardia_ataque",
			"rem_guardia_bloqueo", "rem_guardian_ataque", "rem_guardian_andar"]:
		assert_true(ids.has(id), "falta la tira de remoto %s" % id)
	var bot_ids: PackedStringArray = PackedStringArray()
	for spec: Dictionary in _specs_of(ScBot).specs:
		bot_ids.append(String(spec["id"]))
	for id: String in ["rem_bot_ataque", "rem_bot_correr", "rem_bot_bloqueo", "rem_bot_esquiva", "rem_bot_recibir_golpe",
			"rem_bot_derribado", "rem_bot_muerte"]:
		assert_true(bot_ids.has(id), "falta la tira del bot %s" % id)
	assert_true(ScBlock.STRIP_IDS.has("com_bloqueo_recibir_golpe"), "hay tira de golpe recibido en bloqueo")


func test_edge_trigger_fires_only_on_the_rising_edge() -> void:
	var edge: Callable = Specs.edge(["BLOCK"])
	assert_true(edge.call({"action": "BLOCK"}, {"action": "NONE"}), "NONE -> BLOCK dispara")
	assert_false(edge.call({"action": "BLOCK"}, {"action": "BLOCK"}), "BLOCK mantenido no vuelve a disparar")
	assert_false(edge.call({"action": "NONE"}, {"action": "BLOCK"}), "al soltar no dispara")
	var any_attack: Callable = Specs.edge(["LIGHT", "HEAVY"])
	assert_false(any_attack.call({"action": "HEAVY"}, {"action": "LIGHT"}), "LIGHT -> HEAVY sigue siendo el mismo borde")


func test_has_action_validation_checks_actions_and_weapon() -> void:
	var metas: Array = []
	for action: String in ["NONE", "LIGHT", "LIGHT", "LIGHT", "LIGHT", "NONE"]:
		metas.append({"action": action})
	var info: Dictionary = {"weapon": "sword_shield"}
	assert_true(Specs.has_action(["LIGHT"], 4, [], "sword_shield").call(metas, info), "cuatro fotogramas de LIGHT")
	assert_false(Specs.has_action(["LIGHT"], 5).call(metas, info), "no llega a cinco")
	assert_false(Specs.has_action(["LIGHT"], 2, ["NONE"]).call(metas, info), "una acción prohibida invalida la toma")
	assert_false(Specs.has_action(["LIGHT"], 2, [], "npc_hollow").call(metas, info), "el arma tiene que ser la pedida")


# --- Grabadora ---------------------------------------------------------------------------------

class StubDriver extends RefCounted:
	var root: Node = Node.new()
	var raw_dir: String = ""
	var hit_events: Array = []
	var ch: Object = null
	var notes: PackedStringArray = PackedStringArray()

	func note(text: String) -> void:
		notes.append(text)


func _ring_sample(ms: int, action: String, clip: String, occluded: bool = false) -> Dictionary:
	var img: Image = Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	return {"ms": ms, "game": img, "side": img, "meta": {"ms": ms, "action": action, "phase": 0, "speed": 0.0, "air": "",
			"clip": clip, "clip_t": 0.1, "clip_speed": 1.0, "upper": false, "pos_y": 0.0, "neighbors": 1, "occluded": occluded}}


func test_recorder_extracts_frames_with_pre_roll() -> void:
	var driver := StubDriver.new()
	var rec: Recorder = Recorder.new(driver)
	for i: int in 40:
		rec._ring.append(_ring_sample(1000 + i * Recorder.SAMPLE_MS, "NONE", ""))
	var trigger_ms: int = 1000 + 20 * Recorder.SAMPLE_MS
	var frames: Array[Dictionary] = rec.extract(trigger_ms, 150, 100, 12)
	assert_eq(frames.size(), 12, "doce fotogramas")
	assert_eq(int(frames[0]["ms"]), trigger_ms - 150, "el primero lleva 150 ms de antes del disparo")
	assert_eq(int(frames[1]["ms"]) - int(frames[0]["ms"]), 100, "cada 100 ms")
	assert_eq(rec.extract(500, 150, 100, 12).size(), 0, "si el anillo no llega al principio, no hay tira")
	driver.root.free()


func test_recorder_saves_the_layer_clip_in_meta_json() -> void:
	var driver := StubDriver.new()
	driver.raw_dir = ProjectSettings.globalize_path(SCRATCH_DIR).path_join("raw")
	var rec: Recorder = Recorder.new(driver)
	var frames: Array[Dictionary] = []
	frames.append(_ring_sample(1000, "NONE", ""))
	frames.append(_ring_sample(1050, "LIGHT", "ual2/Sword_Regular_A"))
	frames.append(_ring_sample(1100, "LIGHT", "ual2/Sword_Regular_A", true))
	frames.append(_ring_sample(1150, "NONE", "ual2/Sword_Regular_A_Rec"))
	driver.hit_events.append({"ms": 1100, "kind": "taken", "blocked": true, "parried": false, "amount": 0})
	rec.save_strip(driver.raw_dir, "rem_prueba_ataque", "Prueba", frames, "nota", {"weapon": "sword_shield", "target": {"name": "Bot"}})
	var meta_path: String = driver.raw_dir.path_join("rem_prueba_ataque/ciclo/meta.json")
	if not assert_true(FileAccess.file_exists(meta_path), "se escribe el meta.json"):
		driver.root.free()
		return
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	assert_eq(String(meta["source"]), "online", "viene de la partida en red")
	assert_eq((meta["layer_clips"] as Array).size(), 2, "los clips distintos de la capa de animación: %s" % [meta["layer_clips"]])
	assert_true((meta["layer_clips"] as Array).has("ual2/Sword_Regular_A"), "guarda el clip que reproduce la capa remota")
	assert_eq(int(meta["frames_with_clip"]), 3, "fotogramas con clip")
	assert_eq(int(meta["occluded_frames"]), 1, "cuenta los fotogramas tapados")
	var frames_meta: Array = meta["frames"]
	assert_eq(String(frames_meta[1]["clip"]), "ual2/Sword_Regular_A", "el clip va en cada fotograma")
	assert_eq(String(frames_meta[2]["hit"]), "BLOQUEADO", "el golpe bloqueado del cliente cae en su fotograma")
	assert_false(frames_meta[1].has("hit"), "y no en los demás")
	assert_true(FileAccess.file_exists(driver.raw_dir.path_join("rem_prueba_ataque/ciclo/side_03.png")), "guarda la vista lateral")
	driver.root.free()
	_remove_dir(ProjectSettings.globalize_path(SCRATCH_DIR))


func test_specs_discard_a_take_that_fails_its_validation() -> void:
	var driver := StubDriver.new()
	driver.raw_dir = ProjectSettings.globalize_path(SCRATCH_DIR).path_join("raw_specs")
	var rec: Recorder = Recorder.new(driver)
	var specs: Specs = Specs.new(driver, rec)
	specs.add("rem_prueba_bloqueo", "Prueba", "bot", Specs.edge(["BLOCK"]), 4, 50, 0, "", Specs.has_action(["BLOCK"], 3))
	# Toma buena: cuatro fotogramas de BLOCK.
	for i: int in 8:
		var action: String = "BLOCK" if i >= 2 and i < 6 else "NONE"
		rec._ring.append(_ring_sample(1000 + i * 50, action, "ual2/Sword_Block" if action == "BLOCK" else ""))
	specs.add("rem_prueba_bloqueo_larga", "Prueba larga", "bot", Specs.edge(["BLOCK"]), 4, 50, 0, "", Specs.has_action(["BLOCK"], 6))
	specs.trigger("rem_prueba_bloqueo", 1100)
	rec._ring.append(_ring_sample(1400, "NONE", ""))
	rec._ring.append(_ring_sample(1450, "NONE", ""))
	specs.evaluate("bot")
	assert_true(specs.is_done("rem_prueba_bloqueo"), "una toma que cumple su validación se guarda: %s" % [specs.rejected])
	# Otra toma de la misma acción que pide más fotogramas de BLOCK de los que hay: se descarta y se sigue esperando.
	specs.trigger("rem_prueba_bloqueo_larga", 1100)
	rec._ring.append(_ring_sample(1500, "NONE", ""))
	specs.evaluate("bot")
	assert_false(specs.is_done("rem_prueba_bloqueo_larga"), "una toma que no cumple su validación no se guarda")
	assert_eq(int(specs.rejected.get("rem_prueba_bloqueo_larga", 0)), 1, "y se cuenta como descartada")
	assert_false(specs.is_recording(), "y la grabadora queda libre para la siguiente")
	driver.root.free()
	_remove_dir(ProjectSettings.globalize_path(SCRATCH_DIR))


# --- Python: juntar tiras, índice y orden -------------------------------------------------------

func _python() -> String:
	for candidate: String in ["python", "python3"]:
		if OS.execute(candidate, ["-c", "import PIL"], [], true) == 0:
			return candidate
	return ""


func test_python_tools_compose_strips_and_write_the_index() -> void:
	var python: String = _python()
	if python.is_empty():
		return # sin Python y Pillow en esta máquina no hay nada que comprobar
	var out_dir: String = ProjectSettings.globalize_path(SCRATCH_DIR).path_join("python")
	_remove_dir(out_dir)
	var base: String = out_dir.path_join("raw/rem_prueba_ataque/ciclo")
	DirAccess.make_dir_recursive_absolute(base)
	var frames: Array = []
	var clips: Array[String] = ["", "ual2/Sword_Regular_A", "ual2/Sword_Regular_A", ""]
	var actions: Array[String] = ["NONE", "LIGHT", "LIGHT", "NONE"]
	for i: int in 4:
		var img: Image = Image.create_empty(48, 54, false, Image.FORMAT_RGB8)
		img.fill(Color(0.2, 0.3, 0.4))
		img.save_png(base.path_join("game_%02d.png" % i))
		img.save_png(base.path_join("side_%02d.png" % i))
		frames.append({"k": i, "rt": i * 3, "t": i * 0.05, "action": actions[i], "speed": 0.0, "air": "", "clip": clips[i],
				"clip_t": 0.1, "clip_speed": 1.0, "upper": false, "pos_y": 0.0, "neighbors": 1, "occluded": i == 2})
	var meta: Dictionary = {"id": "rem_prueba_ataque", "name": "ciclo", "title": "Bot remoto: ataque", "desc": "", "note": "",
			"frames": frames, "from": 0, "to": 0, "weapon": "sword_shield", "source": "online"}
	var file: FileAccess = FileAccess.open(base.path_join("meta.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(meta))
	file.close()
	var script_dir: String = ProjectSettings.globalize_path(QUALITY_DIR)
	var output: Array = []
	assert_eq(OS.execute(python, [script_dir.path_join("compose_strips.py"), out_dir.path_join("raw"), out_dir], output, true), 0,
			"compose_strips.py termina bien: %s" % [output])
	assert_true(FileAccess.file_exists(out_dir.path_join("animacion/remoto/rem_prueba_ataque.png")), "la tira de cámara del juego va a animacion/remoto")
	assert_true(FileAccess.file_exists(out_dir.path_join("animacion/remoto_lado/rem_prueba_ataque.png")), "la lateral va a animacion/remoto_lado")
	output.clear()
	assert_eq(OS.execute(python, [script_dir.path_join("make_index.py"), out_dir], output, true), 0, "make_index.py termina bien: %s" % [output])
	var index: String = FileAccess.get_file_as_string(out_dir.path_join("indice.md"))
	assert_true(index.contains("rem_prueba_ataque.png"), "el índice lista la tira")
	assert_true(index.contains("Sword_Regular_A"), "y el clip que enseñó la capa de animación")
	assert_true(index.contains("2/2"), "y cuántos fotogramas de acción tienen clip")
	_remove_dir(ProjectSettings.globalize_path(SCRATCH_DIR))


func test_run_py_lists_areas_without_godot() -> void:
	var python: String = ""
	for candidate: String in ["python", "python3"]:
		if OS.execute(candidate, ["--version"], [], true) == 0:
			python = candidate
			break
	if python.is_empty():
		return
	var output: Array = []
	var code: int = OS.execute(python, [ProjectSettings.globalize_path(QUALITY_DIR).path_join("run.py"), "listar"], output, true)
	assert_eq(code, 0, "run.py listar termina bien: %s" % [output])
	var text: String = "\n".join(output)
	for area: String in ["animacion", "mapa", "interfaz", "mundo", "combate", "video"]:
		assert_true(text.contains(area), "lista el área %s" % area)


func _remove_dir(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		_remove_dir(path.path_join(sub))
	for file: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
