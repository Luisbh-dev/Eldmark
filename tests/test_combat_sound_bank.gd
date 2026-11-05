extends TestCase
## Tests of the combat and footstep sound banks (ART-11): that each group has all its files, that the
## table matches that of [code]niveles.json[/code], which group sounds for each material and surface, the
## sweep synchronization and the combat audio ([CombatAudio]).

const NIVELES_PATH: String = "res://assets/audio/sfx/niveles.json"


func before_each() -> void:
	CombatSoundBank.clear_cache()


func test_every_group_file_exists_and_loads() -> void:
	for group: StringName in CombatSoundBank.GROUPS:
		var files: PackedStringArray = CombatSoundBank.files_of(group)
		assert_true(files.size() >= 2, "%s has variants" % group)
		for path: String in files:
			assert_true(ResourceLoader.exists(path), "%s exists" % path)
		assert_not_null(CombatSoundBank.stream_of(group), "%s gives a sound" % group)


func test_table_matches_the_levels_file() -> void:
	var text: String = FileAccess.get_file_as_string(NIVELES_PATH)
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed is Dictionary, "niveles.json is read")
	if not parsed is Dictionary:
		return
	var groups: Dictionary = (parsed as Dictionary).get("grupos", {})
	var checked: int = 0
	for group: StringName in CombatSoundBank.GROUPS:
		if not groups.has(String(group)):
			continue
		checked += 1
		var entry: Dictionary = groups[String(group)]
		assert_eq(CombatSoundBank.files_of(group).size(), (entry["archivos"] as Array).size(),
				"%s: same number of variants" % group)
		assert_near(CombatSoundBank.volume_db_of(group), float(entry["volume_db"]), 0.001,
				"%s: same volume trim" % group)
		assert_true(CombatSoundBank.volume_db_of(group) <= 0.0, "%s: the trim is never positive" % group)
	assert_true(checked >= 14, "the table shares at least 14 groups with niveles.json")


func test_every_surface_has_a_step_bank() -> void:
	for surface: StringName in CombatSoundBank.SURFACES:
		var group: StringName = CombatSoundBank.step_group(surface)
		assert_true(CombatSoundBank.has_group(group), "%s has a footstep bank" % surface)
	assert_true(CombatSoundBank.step_group(CombatSoundBank.SURFACE_GRASS)
			!= CombatSoundBank.step_group(CombatSoundBank.SURFACE_STONE), "grass and stone sound different")
	assert_true(CombatSoundBank.step_group(CombatSoundBank.SURFACE_WOOD)
			!= CombatSoundBank.step_group(CombatSoundBank.SURFACE_DIRT), "wood and dirt sound different")
	assert_true(CombatSoundBank.step_pitch(CombatSoundBank.SURFACE_WATER) < 1.0, "water lowers the pitch")


func test_impact_group_by_material_block_and_parry() -> void:
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.FLESH), &"hit_flesh")
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.MAIL), &"hit_mail")
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.GAMBESON), &"hit_gambeson")
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.FLESH, true), &"hit_shield_wood")
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.SHIELD_METAL, true), &"hit_shield_metal")
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.FLESH, true, true), &"clash_metal")
	assert_eq(CombatSoundBank.impact_group(CombatSoundBank.Armor.HOLLOW), &"hit_flesh")


func test_randomizer_varies_pitch_and_volume() -> void:
	var stream: AudioStream = CombatSoundBank.stream_of(&"hit_flesh")
	assert_true(stream is AudioStreamRandomizer, "each group is an AudioStreamRandomizer")
	var randomizer: AudioStreamRandomizer = stream as AudioStreamRandomizer
	assert_true(randomizer.random_pitch > 1.0, "the pitch varies")
	assert_true(randomizer.random_volume_offset_db > 0.0, "the volume varies")
	assert_eq(randomizer.streams_count, 5, "with the five variants")


func test_footstep_surface_from_texture_names() -> void:
	assert_eq(FootstepSurface.kind_of_texture_name("Losa de calzada"), &"stone")
	assert_eq(FootstepSurface.kind_of_texture_name("Roca 2"), &"stone")
	assert_eq(FootstepSurface.kind_of_texture_name("Hierba seca"), &"grass")
	assert_eq(FootstepSurface.kind_of_texture_name("Tierra batida"), &"dirt")
	assert_eq(FootstepSurface.kind_of_texture_name("Tablas de madera"), &"wood")
	assert_eq(FootstepSurface.kind_of_texture_name("Pino 1"), &"", "what is not recognized does not decide")


func test_swing_sound_peak_lands_in_the_middle_of_the_active_window() -> void:
	# niveles.json: start = windup + active / 2 - peak.
	assert_near(CombatAudio.swing_delay(0.2, 0.1, false), 0.161, 0.002, "light 1")
	assert_near(CombatAudio.swing_delay(0.18, 0.1, false), 0.141, 0.002, "light 2")
	assert_near(CombatAudio.swing_delay(0.4, 0.12, true), 0.263, 0.002, "heavy")
	assert_eq(CombatAudio.swing_delay(0.01, 0.02, true), 0.0, "never negative")


func test_combat_audio_counts_and_does_not_need_a_director() -> void:
	var audio := CombatAudio.new()
	tree.root.add_child(audio)
	audio.play_impact(Vector3.ZERO, CombatSoundBank.Armor.FLESH, false, false, false, true)
	audio.play_impact(Vector3.ZERO, CombatSoundBank.Armor.FLESH, true, true, false, false)
	audio.play_impact(Vector3.ZERO, CombatSoundBank.Armor.FLESH, false, false, true, true)
	audio.play_impact(Vector3.ZERO, CombatSoundBank.Armor.HOLLOW, false, false, false, false)
	audio.play_step(Vector3.ZERO, &"stone", 0.5, true)
	audio.play_step(Vector3.ZERO, &"grass", 0.5, true)
	audio.play_land(Vector3.ZERO, &"wood", 1.0, true)
	assert_eq(audio.get_play_count(&"hit_flesh"), 2, "flesh: the normal hit and the Hollow's")
	assert_eq(audio.get_play_count(&"hit_shield_wood"), 1, "shield")
	assert_eq(audio.get_play_count(&"clash_metal"), 1, "parry")
	assert_eq(audio.get_play_count(&"hollow_hurt"), 1, "the Hollow also growls")
	assert_eq(audio.get_play_count(&"step_stone"), 1)
	assert_eq(audio.get_play_count(&"step_grass"), 1)
	assert_eq(audio.get_play_count(&"step_wood"), 1)
	audio.free()


func test_combat_audio_plays_through_the_director_with_priority_for_own_sounds() -> void:
	var director := AudioDirector.new()
	director.load_volumes_on_ready = false
	tree.root.add_child(director)
	var audio := CombatAudio.new()
	tree.root.add_child(audio)
	audio.play_impact(Vector3(1.0, 0.0, 0.0), CombatSoundBank.Armor.FLESH, false, false, false, true)
	var stats: Dictionary = director.get_stats()
	assert_eq(stats["requested"], 1, "a request reached the director")
	audio.play_step(Vector3(200.0, 0.0, 0.0), &"grass", 0.0, false)
	assert_eq(director.get_stats()["requested"], 1, "a foreign step at 200 m is not even requested")
	audio.free()
	director.free()
