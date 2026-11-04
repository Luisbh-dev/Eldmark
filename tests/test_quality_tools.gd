extends TestCase
## Tests for the quality capture bench (TEC-50, [code]tools/quality/[/code]).
## [br][br]
## The bench needs a window and a GPU, so here only what can be tested without them is covered: that all its scripts load (a
## syntax error is discovered here and not after half an hour of captures), that the strip scripts cover what the quality
## plan says (each NPC in the catalog has its set of strips; guards and Guardians too), that the strips of characters seen from another
## client have non-repeating ids and well-formed conditions, the recorder's pure logic (the frame ring, the validation of
## takes and the [code]meta.json[/code] with the animation layer's clip) and the Python pieces (joining strips, index, order) with
## dummy data, if Python and Pillow are on the machine.

const QUALITY_DIR: String = "res://tools/quality"
const AnimActions = preload("res://tools/quality/anim_actions.gd")
const Recorder = preload("res://tools/quality/strip_recorder.gd")
const Specs = preload("res://tools/quality/strip_specs.gd")
const ScBot = preload("res://tools/quality/sc_remotos_bot.gd")
const ScPnj = preload("res://tools/quality/sc_remotos_pnj.gd")
const ScBlock = preload("res://tools/quality/sc_bloqueo.gd")

## Strips that must exist for each NPC in the sandbox.
const NPC_STRIPS: Array[String] = ["reposo", "andar", "esprintar", "ataque_ligero", "ataque_fuerte", "bloqueo",
		"recibir_golpe", "muerte"]
## Target keys understood by the remote scenarios.
const TARGET_KEYS: Array[String] = ["bot", "hueco", "capitan", "guardia", "guardian", "local"]
const SCRATCH_DIR: String = "res://build/test_quality_tools"


# --- Smoke -----------------------------------------------------------------------------------

func test_every_quality_script_loads() -> void:
	var dir: DirAccess = DirAccess.open(QUALITY_DIR)
	if not assert_not_null(dir, "%s exists" % QUALITY_DIR):
		return
	var count: int = 0
	for file: String in dir.get_files():
		if not file.ends_with(".gd"):
			continue
		var path: String = QUALITY_DIR.path_join(file)
		var script: GDScript = load(path) as GDScript
		if assert_not_null(script, "%s loads (a syntax error would leave it null)" % path):
			assert_true(script.can_instantiate(), "%s can be instantiated" % path)
		count += 1
	assert_true(count >= 12, "the bench has its scripts (%d)" % count)


func test_command_line_tools_have_their_entry_point() -> void:
	for file: String in ["anim_strips.gd", "online_driver.gd"]:
		var script: GDScript = load(QUALITY_DIR.path_join(file)) as GDScript
		if not assert_not_null(script):
			continue
		assert_true(script.get_script_method_list().any(
				func(method: Dictionary) -> bool: return method["name"] == "_initialize"),
				"%s is a command-line script (SceneTree._initialize)" % file)
	for file: String in ["sc_combate.gd", "sc_mapa.gd", "sc_mundo.gd", "sc_interfaz.gd", "sc_extras.gd", "sc_front.gd",
			"sc_gallery.gd", "sc_realm.gd", "sc_remotos_bot.gd", "sc_remotos_pnj.gd", "sc_bloqueo.gd", "sc_video.gd"]:
		var script: GDScript = load(QUALITY_DIR.path_join(file)) as GDScript
		if not assert_not_null(script):
			continue
		assert_true(script.get_script_method_list().any(
				func(method: Dictionary) -> bool: return method["name"] == "run"),
				"%s is a driver scenario (func run(d))" % file)


# --- Sandbox strip scripts --------------------------------------------------------------------

func test_npc_profiles_cover_every_npc_weapon_of_the_catalog() -> void:
	var profiles: Array[String] = AnimActions.npc_profiles()
	var expected: Dictionary = {}
	for id: StringName in NpcCatalog.ids():
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		expected[String(definition.weapon_id).trim_prefix("npc_")] = true
	assert_eq(profiles.size(), expected.size(), "one profile per distinct NPC weapon in the catalog")
	for short: String in expected.keys():
		assert_true(profiles.has(short), "profile %s has strips" % short)
	# The four the quality plan asks for: Hollow, Captain, guards and Gate Guardians.
	for short: String in ["hollow", "captain", "guard", "guardian"]:
		assert_true(profiles.has(short), "there are strips for %s" % short)


func test_every_npc_weapon_has_a_complete_set_of_strips() -> void:
	var ids: PackedStringArray = AnimActions.ids_of(AnimActions.npc_actions())
	for short: String in AnimActions.npc_profiles():
		assert_true(CombatCatalog.weapon_id(StringName("npc_" + short)) > 0, "npc_%s exists in the combat catalog" % short)
		for strip: String in NPC_STRIPS:
			assert_true(ids.has("npc_%s_%s" % [short, strip]), "strip npc_%s_%s is missing" % [short, strip])


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
			assert_true(profiles.has(short), "weapon %s has NPC strips (a catalog NPC uses it)" % file)


func test_strip_ids_are_unique_and_windows_fit_inside_their_scripts() -> void:
	var seen: Dictionary = {}
	var all: Array[Dictionary] = []
	all.append_array(AnimActions.player_actions())
	all.append_array(AnimActions.npc_actions())
	assert_true(all.size() > 60, "there is a good handful of actions (%d)" % all.size())
	for act: Dictionary in all:
		var id: String = String(act["id"])
		assert_false(seen.has(id), "repeated id: %s" % id)
		seen[id] = true
		var tl: AnimActions.TL = act["tl"] as AnimActions.TL
		var end: int = 0
		for seg: Dictionary in tl.segs:
			end = maxi(end, int(seg["b"]))
		assert_true(not (act["windows"] as Array).is_empty(), "%s has windows" % id)
		for win: Dictionary in act["windows"]:
			if win.has("dyn_warm"):
				assert_true(int(win["dyn_warm"]) + 200 <= end, "%s: the script covers the locomotion cycle" % id)
				continue
			assert_true(int(win["from"]) < int(win["to"]), "%s [%s]: the window advances" % [id, win["name"]])
			assert_true(int(win["to"]) <= end, "%s [%s]: the script lasts longer than the window (%d <= %d)" % [id, win["name"], win["to"], end])
			assert_true(int(win["frames"]) >= 2, "%s [%s]: at least two frames" % [id, win["name"]])


func test_player_strips_cover_what_the_quality_plan_asks_for() -> void:
	var ids: PackedStringArray = AnimActions.ids_of(AnimActions.player_actions())
	for id: String in ["loc_reposo", "loc_andar", "loc_trotar", "loc_esprintar", "loc_lateral_izquierda", "loc_lateral_derecha",
			"loc_atras", "com_ligero_1", "com_ligero_2", "com_ligero_3", "com_combo_completo", "com_fuerte", "com_bloqueo",
			"com_bloqueo_andando", "com_esquiva_delante", "com_esquiva_atras", "com_esquiva_izquierda", "com_esquiva_derecha",
			"com_recibir_golpe", "com_muerte", "com_muerte_corriendo", "com_derribado", "arc_ligero", "arc_cargado"]:
		assert_true(ids.has(id), "strip %s of the animation bar is missing" % id)


# --- Strips of characters seen from another client ---------------------------------------------

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
		assert_true(specs.specs.size() >= 9, "the scenario defines its strips")
		for spec: Dictionary in specs.specs:
			var id: String = String(spec["id"])
			assert_true(id.begins_with("rem_"), "%s starts with rem_ (it goes to the remoto and remoto_lado folders)" % id)
			assert_false(seen.has(id), "repeated id across scenarios: %s" % id)
			seen[id] = true
			assert_true(TARGET_KEYS.has(String(spec["target"])), "%s: known target (%s)" % [id, spec["target"]])
			assert_true((spec["cond"] as Callable).is_valid(), "%s has a condition" % id)
			assert_true(int(spec["n"]) == 12, "%s: 12 frames, like the other strips" % id)
			assert_true(int(spec["interval"]) >= Recorder.SAMPLE_MS, "%s: the interval does not go below the recorder's cadence" % id)
			assert_true(int(spec["pre"]) >= 0, "%s: carries the start of the action" % id)


func test_remote_strips_include_guards_and_gate_guardians() -> void:
	var ids: PackedStringArray = PackedStringArray()
	for spec: Dictionary in _specs_of(ScPnj).specs:
		ids.append(String(spec["id"]))
	for id: String in ["rem_hueco_ataque", "rem_hueco_muerte", "rem_capitan_ataque", "rem_capitan_muerte", "rem_guardia_ataque",
			"rem_guardia_bloqueo", "rem_guardian_ataque", "rem_guardian_andar"]:
		assert_true(ids.has(id), "remote strip %s is missing" % id)
	var bot_ids: PackedStringArray = PackedStringArray()
	for spec: Dictionary in _specs_of(ScBot).specs:
		bot_ids.append(String(spec["id"]))
	for id: String in ["rem_bot_ataque", "rem_bot_correr", "rem_bot_bloqueo", "rem_bot_esquiva", "rem_bot_recibir_golpe",
			"rem_bot_derribado", "rem_bot_muerte"]:
		assert_true(bot_ids.has(id), "bot strip %s is missing" % id)
	assert_true(ScBlock.STRIP_IDS.has("com_bloqueo_recibir_golpe"), "there is a strip for a hit received while blocking")


func test_edge_trigger_fires_only_on_the_rising_edge() -> void:
	var edge: Callable = Specs.edge(["BLOCK"])
	assert_true(edge.call({"action": "BLOCK"}, {"action": "NONE"}), "NONE -> BLOCK fires")
	assert_false(edge.call({"action": "BLOCK"}, {"action": "BLOCK"}), "a held BLOCK does not fire again")
	assert_false(edge.call({"action": "NONE"}, {"action": "BLOCK"}), "releasing does not fire")
	var any_attack: Callable = Specs.edge(["LIGHT", "HEAVY"])
	assert_false(any_attack.call({"action": "HEAVY"}, {"action": "LIGHT"}), "LIGHT -> HEAVY is still the same edge")


func test_has_action_validation_checks_actions_and_weapon() -> void:
	var metas: Array = []
	for action: String in ["NONE", "LIGHT", "LIGHT", "LIGHT", "LIGHT", "NONE"]:
		metas.append({"action": action})
	var info: Dictionary = {"weapon": "sword_shield"}
	assert_true(Specs.has_action(["LIGHT"], 4, [], "sword_shield").call(metas, info), "four frames of LIGHT")
	assert_false(Specs.has_action(["LIGHT"], 5).call(metas, info), "does not reach five")
	assert_false(Specs.has_action(["LIGHT"], 2, ["NONE"]).call(metas, info), "a forbidden action invalidates the take")
	assert_false(Specs.has_action(["LIGHT"], 2, [], "npc_hollow").call(metas, info), "the weapon has to be the requested one")


# --- Recorder ----------------------------------------------------------------------------------

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
	assert_eq(frames.size(), 12, "twelve frames")
	assert_eq(int(frames[0]["ms"]), trigger_ms - 150, "the first carries 150 ms from before the shot")
	assert_eq(int(frames[1]["ms"]) - int(frames[0]["ms"]), 100, "every 100 ms")
	assert_eq(rec.extract(500, 150, 100, 12).size(), 0, "if the ring does not reach the start, there is no strip")
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
	if not assert_true(FileAccess.file_exists(meta_path), "meta.json is written"):
		driver.root.free()
		return
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	assert_eq(String(meta["source"]), "online", "it comes from the networked game")
	assert_eq((meta["layer_clips"] as Array).size(), 2, "the distinct clips of the animation layer: %s" % [meta["layer_clips"]])
	assert_true((meta["layer_clips"] as Array).has("ual2/Sword_Regular_A"), "saves the clip the remote layer plays")
	assert_eq(int(meta["frames_with_clip"]), 3, "frames with a clip")
	assert_eq(int(meta["occluded_frames"]), 1, "counts the covered frames")
	var frames_meta: Array = meta["frames"]
	assert_eq(String(frames_meta[1]["clip"]), "ual2/Sword_Regular_A", "the clip is in every frame")
	assert_eq(String(frames_meta[2]["hit"]), "BLOQUEADO", "the client's blocked hit lands on its frame")
	assert_false(frames_meta[1].has("hit"), "and not on the others")
	assert_true(FileAccess.file_exists(driver.raw_dir.path_join("rem_prueba_ataque/ciclo/side_03.png")), "saves the side view")
	driver.root.free()
	_remove_dir(ProjectSettings.globalize_path(SCRATCH_DIR))


func test_specs_discard_a_take_that_fails_its_validation() -> void:
	var driver := StubDriver.new()
	driver.raw_dir = ProjectSettings.globalize_path(SCRATCH_DIR).path_join("raw_specs")
	var rec: Recorder = Recorder.new(driver)
	var specs: Specs = Specs.new(driver, rec)
	specs.add("rem_prueba_bloqueo", "Prueba", "bot", Specs.edge(["BLOCK"]), 4, 50, 0, "", Specs.has_action(["BLOCK"], 3))
	# Good take: four frames of BLOCK.
	for i: int in 8:
		var action: String = "BLOCK" if i >= 2 and i < 6 else "NONE"
		rec._ring.append(_ring_sample(1000 + i * 50, action, "ual2/Sword_Block" if action == "BLOCK" else ""))
	specs.add("rem_prueba_bloqueo_larga", "Prueba larga", "bot", Specs.edge(["BLOCK"]), 4, 50, 0, "", Specs.has_action(["BLOCK"], 6))
	specs.trigger("rem_prueba_bloqueo", 1100)
	rec._ring.append(_ring_sample(1400, "NONE", ""))
	rec._ring.append(_ring_sample(1450, "NONE", ""))
	specs.evaluate("bot")
	assert_true(specs.is_done("rem_prueba_bloqueo"), "a take that meets its validation is saved: %s" % [specs.rejected])
	# Another take of the same action that asks for more BLOCK frames than there are: it is discarded and the wait continues.
	specs.trigger("rem_prueba_bloqueo_larga", 1100)
	rec._ring.append(_ring_sample(1500, "NONE", ""))
	specs.evaluate("bot")
	assert_false(specs.is_done("rem_prueba_bloqueo_larga"), "a take that does not meet its validation is not saved")
	assert_eq(int(specs.rejected.get("rem_prueba_bloqueo_larga", 0)), 1, "and it is counted as discarded")
	assert_false(specs.is_recording(), "and the recorder is free for the next one")
	driver.root.free()
	_remove_dir(ProjectSettings.globalize_path(SCRATCH_DIR))


# --- Python: joining strips, index and order ----------------------------------------------------

func _python() -> String:
	for candidate: String in ["python", "python3"]:
		if OS.execute(candidate, ["-c", "import PIL"], [], true) == 0:
			return candidate
	return ""


func test_python_tools_compose_strips_and_write_the_index() -> void:
	var python: String = _python()
	if python.is_empty():
		return # without Python and Pillow on this machine there is nothing to check
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
			"compose_strips.py finishes fine: %s" % [output])
	assert_true(FileAccess.file_exists(out_dir.path_join("animacion/remoto/rem_prueba_ataque.png")), "the game camera strip goes to animacion/remoto")
	assert_true(FileAccess.file_exists(out_dir.path_join("animacion/remoto_lado/rem_prueba_ataque.png")), "the side one goes to animacion/remoto_lado")
	output.clear()
	assert_eq(OS.execute(python, [script_dir.path_join("make_index.py"), out_dir], output, true), 0, "make_index.py finishes fine: %s" % [output])
	var index: String = FileAccess.get_file_as_string(out_dir.path_join("indice.md"))
	assert_true(index.contains("rem_prueba_ataque.png"), "the index lists the strip")
	assert_true(index.contains("Sword_Regular_A"), "and the clip the animation layer showed")
	assert_true(index.contains("2/2"), "and how many action frames have a clip")
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
	assert_eq(code, 0, "run.py list finishes fine: %s" % [output])
	var text: String = "\n".join(output)
	for area: String in ["animacion", "mapa", "interfaz", "mundo", "combate", "video"]:
		assert_true(text.contains(area), "lists the area %s" % area)


func _remove_dir(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		_remove_dir(path.path_join(sub))
	for file: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
