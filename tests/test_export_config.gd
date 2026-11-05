extends TestCase
## Tests for the export configuration (TEC-12): the two presets of [code]export_presets.cfg[/code]
## (Windows client and Linux dedicated server), that their filters leave out [code]build/[/code],
## [code]docs/[/code], [code]tests/[/code] and [code]platform/[/code] (the Go service, which Godot does not even
## scan thanks to its [code].gdignore[/code]) without removing anything the game loads, that the
## scripts [code]tools/export.sh[/code] and [code]tools/export.ps1[/code] use the same presets, and,
## in a separate process, that exporting the server pack ([code]--export-pack[/code], which does not need
## the export templates) yields a trimmed pack, with what is needed and without what is surplus.
## [br][br]
## Truly exporting (the executable) needs the 4.7.2 export templates, which cannot be
## installed from the tests: that is done by hand with [code]tools/export.sh[/code] (see docs/getting-started.md, section Export).

const PRESETS_PATH: String = "res://export_presets.cfg"
const CLIENT_PRESET: String = "Cliente Windows"
const SERVER_PRESET: String = "Servidor Linux"
const SCRIPT_SH: String = "res://tools/export.sh"
const SCRIPT_PS1: String = "res://tools/export.ps1"
## Folders that no pack should carry.
const FORBIDDEN_DIRS: Array[String] = ["build/", "docs/", "tests/", "tools/", "exports/", ".github/", "platform/"]
## Folders and files that the game loads and that no filter can remove.
const REQUIRED_PATHS: Array[String] = [
	"project.godot", "default_bus_layout.tres", "export_presets.cfg",
	"scripts/boot.gd", "scripts/shared/player_character.gd", "scripts/server/zone_server.gd",
	"scripts/client/client_main.gd", "scenes/boot.tscn", "scenes/server/server_main.tscn",
	"scenes/client/client_main.tscn", "scenes/ui/hud.tscn",
	"scenes/world/zones/vado_gris/vado_gris.tscn", "data/combat/combat_rules.tres",
	"data/characters/appearance_catalog.tres", "data/characters/races/race_vardheim.tres",
	"data/progression/level_curve.tres", "data/items/weapon/sword_shield_vado.tres",
	"data/items/consumable/potion_health.tres",
	"assets/ui/theme/eldmark_theme.tres", "assets/emblems/vardheim.svg",
	"addons/terrain_3d/terrain.gdextension", "addons/terrain_3d/LICENSE.txt",
	"addons/proton_scatter/LICENSE", "assets/LICENSES.md",
]
const PACK_PATH: String = "res://build/export_test/server_pack.zip"
## Maximum seconds to wait for the exporting process (a test phase allows 30).
const PACK_TIMEOUT_SECONDS: float = 26.0

var _presets: ConfigFile = ConfigFile.new()


func before_each() -> void:
	assert_eq(_presets.load(PRESETS_PATH), OK, "export_presets.cfg is read as a settings file")


func after_each() -> void:
	if FileAccess.file_exists(PACK_PATH):
		DirAccess.remove_absolute(PACK_PATH)


# The preset with the given name (\"preset.0\", \"preset.1\"...).
func _section_of(preset_name: String) -> String:
	for section: String in _presets.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and _presets.get_value(section, "name", "") == preset_name:
			return section
	return ""


func _value(section: String, key: String) -> Variant:
	return _presets.get_value(section, key, null)


# Exclusion patterns of a preset, already split.
func _excludes(section: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for pattern: String in String(_value(section, "exclude_filter")).split(","):
		if not pattern.strip_edges().is_empty():
			result.append(pattern.strip_edges())
	return result


# true if any pattern in [param patterns] (with wildcards * and ?) matches [param path].
func _matches_any(path: String, patterns: PackedStringArray) -> bool:
	for pattern: String in patterns:
		if path.match(pattern):
			return true
	return false


# --- The presets ------------------------------------------------------------------------------

func test_there_are_exactly_the_two_presets() -> void:
	var names: Array[String] = []
	for section: String in _presets.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			names.append(String(_presets.get_value(section, "name")))
			assert_true(_presets.has_section(section + ".options"), "%s has its options" % section)
	names.sort()
	assert_eq(names, [CLIENT_PRESET, SERVER_PRESET] as Array[String])


func test_the_client_preset_is_windows_x86_64() -> void:
	var section: String = _section_of(CLIENT_PRESET)
	if not assert_false(section.is_empty(), "the client preset exists"):
		return
	assert_eq(_value(section, "platform"), "Windows Desktop")
	assert_eq(_value(section, "dedicated_server"), false, "the client is not a dedicated server")
	assert_eq(_value(section, "export_filter"), "all_resources", "the client carries all the resources")
	assert_eq(_presets.get_value(section + ".options", "binary_format/architecture"), "x86_64")
	assert_eq(_presets.get_value(section + ".options", "binary_format/embed_pck"), false,
			"the .pck goes separately, next to the executable")
	assert_eq(_presets.get_value(section + ".options", "texture_format/s3tc_bptc"), true,
			"compressed textures for the desktop")
	assert_true(String(_value(section, "export_path")).begins_with("exports/windows/"))
	assert_true(String(_value(section, "export_path")).ends_with(".exe"))


func test_the_server_preset_is_a_dedicated_linux_x86_64_server() -> void:
	var section: String = _section_of(SERVER_PRESET)
	if not assert_false(section.is_empty(), "the server preset exists"):
		return
	assert_eq(_value(section, "platform"), "Linux")
	assert_eq(_value(section, "dedicated_server"), true, "export as dedicated server")
	assert_eq(_value(section, "export_filter"), "customized", "with resource stripping by folder")
	assert_eq(_presets.get_value(section + ".options", "binary_format/architecture"), "x86_64")
	assert_eq(_presets.get_value(section + ".options", "texture_format/s3tc_bptc"), true,
			"the terrain textures (Terrain3D validates them) are exported compressed")
	assert_true(String(_value(section, "export_path")).begins_with("exports/server/"))
	assert_false(String(_value(section, "export_path")).ends_with(".exe"))
	# Stripping: the visual layer out, but never \"remove\" (the zone scenes reference models,
	# materials and animations and the server could not load them).
	var files: Dictionary = _value(section, "customized_files")
	for visual_dir: String in ["res://assets/models/", "res://assets/materials/",
			"res://assets/audio/", "res://assets/animations/"]:
		assert_eq(files.get(visual_dir), "strip", "%s is stripped" % visual_dir)
	for path: String in files:
		assert_eq(files[path], "strip", "%s: it is only stripped, never removed" % path)
		assert_false(path.begins_with("res://scripts") or path.begins_with("res://scenes")
				or path.begins_with("res://data"), "%s: the stripping does not touch code, scenes or data" % path)
	assert_false(files.has("res://assets/textures/"),
			"the terrain textures are not stripped: Terrain3D would log errors when loading them")


func test_both_presets_keep_the_development_folders_out_but_the_licences_in() -> void:
	for preset_name: String in [CLIENT_PRESET, SERVER_PRESET]:
		var section: String = _section_of(preset_name)
		var excludes: PackedStringArray = _excludes(section)
		for dir: String in FORBIDDEN_DIRS:
			assert_true(_matches_any(dir + "algo.txt", excludes), "%s excludes %s" % [preset_name, dir])
			assert_true(_matches_any(dir + "sub/archivo.gd", excludes), "%s excludes %s in depth" % [preset_name, dir])
		assert_true(_matches_any("scenes/tests/ui_gallery.tscn", excludes), "and the development scenes")
		var includes: PackedStringArray = PackedStringArray()
		for pattern: String in String(_value(section, "include_filter")).split(","):
			includes.append(pattern.strip_edges())
		for licence: String in ["addons/terrain_3d/LICENSE.txt", "addons/proton_scatter/LICENSE",
				"assets/LICENSES.md", "assets/fonts/OFL-Cinzel.txt", "assets/fonts/OFL-IMFellEnglishSC.txt",
				"assets/fonts/OFL-NotoSans.txt"]:
			assert_true(_matches_any(licence, includes), "%s carries %s (the MIT license requires it)" % [preset_name, licence])
			assert_true(FileAccess.file_exists("res://" + licence), "%s exists" % licence)


func test_no_filter_removes_what_the_game_loads() -> void:
	for preset_name: String in [CLIENT_PRESET, SERVER_PRESET]:
		var excludes: PackedStringArray = _excludes(_section_of(preset_name))
		for path: String in REQUIRED_PATHS:
			assert_true(FileAccess.file_exists("res://" + path), "%s exists" % path)
			assert_false(_matches_any(path, excludes), "%s does not exclude %s" % [preset_name, path])
		# All the zone scenes and the scripts that client and server load.
		for zone_id: StringName in Zones.get_zone_ids():
			var scene: String = Zones.get_scene_path(zone_id).trim_prefix("res://")
			assert_false(_matches_any(scene, excludes), "%s does not exclude the zone %s" % [preset_name, zone_id])
		for dir: String in ["scripts/client", "scripts/server", "scripts/shared", "scripts/world"]:
			for file_name: String in DirAccess.get_files_at("res://" + dir):
				assert_false(_matches_any(dir + "/" + file_name, excludes),
						"%s does not exclude %s/%s" % [preset_name, dir, file_name])
	# The test filter is not so broad as to remove anything else: the check detects what
	# should be left out.
	var sample: PackedStringArray = _excludes(_section_of(SERVER_PRESET))
	assert_true(_matches_any("tests/test_case.gd", sample))
	assert_true(_matches_any("docs/social.md", sample))
	assert_true(_matches_any("platform/internal/migrate/migrations/0001_accounts.up.sql", sample))
	assert_false(_matches_any("scripts/client/audio/audio_director.gd", sample))


func test_exports_are_not_tracked() -> void:
	var ignore: String = FileAccess.get_file_as_string("res://.gitignore")
	assert_true(ignore.contains("/exports/"), "what is exported is not versioned")
	assert_true(ignore.contains("/build/"))


func test_godot_does_not_scan_the_platform_service() -> void:
	# platform/ is the Go service (docs/platform.md §2.1): Godot neither imports nor exports it.
	assert_true(FileAccess.file_exists("res://platform/.gdignore"), "platform/ carries .gdignore")
	assert_true(FileAccess.file_exists("res://platform/go.mod"), "and is the Go module")


# --- The export scripts -----------------------------------------------------------------------

func test_the_export_scripts_use_the_presets_and_their_paths() -> void:
	var server_out: String = String(_value(_section_of(SERVER_PRESET), "export_path"))
	var client_out: String = String(_value(_section_of(CLIENT_PRESET), "export_path"))
	for path: String in [SCRIPT_SH, SCRIPT_PS1]:
		assert_true(FileAccess.file_exists(path), "%s exists" % path)
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.contains("'%s'" % CLIENT_PRESET) or text.contains("\"%s\"" % CLIENT_PRESET),
				"%s uses the preset \"%s\"" % [path, CLIENT_PRESET])
		assert_true(text.contains("'%s'" % SERVER_PRESET) or text.contains("\"%s\"" % SERVER_PRESET),
				"%s uses the preset \"%s\"" % [path, SERVER_PRESET])
		assert_true(text.contains(server_out), "%s writes the server to %s" % [path, server_out])
		assert_true(text.contains(client_out), "%s writes the client to %s" % [path, client_out])
		assert_true(text.contains("--export-pack"), "%s supports exporting only the pack" % path)
		assert_true(text.contains("export_templates"), "%s checks the export templates" % path)
		assert_true(text.contains("lfs pull"), "%s warns if the LFS objects are missing" % path)
		assert_true(text.contains("--headless"), "%s exports without a window" % path)
		assert_true(text.contains("run-server.sh"), "%s leaves the server launcher" % path)
	var shell: String = FileAccess.get_file_as_string(SCRIPT_SH)
	assert_true(shell.begins_with("#!/usr/bin/env bash"), "export.sh is a bash script")
	assert_false(shell.contains("\r"), "with LF line endings")
	# PowerShell 5.1 reads a .ps1 without a BOM as ANSI: with accents it needs the UTF-8 mark.
	var ps_bytes: PackedByteArray = FileAccess.get_file_as_bytes(SCRIPT_PS1)
	assert_true(ps_bytes.size() > 3 and ps_bytes[0] == 0xEF and ps_bytes[1] == 0xBB and ps_bytes[2] == 0xBF,
			"export.ps1 carries the UTF-8 mark (BOM)")


func test_the_shell_script_is_valid_and_dry_runs() -> void:
	if OS.get_name() == "Windows":
		return
	var script: String = ProjectSettings.globalize_path(SCRIPT_SH)
	if not FileAccess.file_exists(SCRIPT_SH) or OS.execute("bash", ["--version"], []) != 0:
		return
	var syntax: Array = []
	assert_eq(OS.execute("bash", ["-n", script], syntax, true), 0, "export.sh is syntactically correct: %s" % [syntax])
	assert_true((FileAccess.get_unix_permissions(SCRIPT_SH) & FileAccess.UNIX_EXECUTE_OWNER) != 0, "export.sh is executable")
	# The script looks for Godot in GODOT or in the PATH; it is given the one running the test so as not to depend
	# on there being a \"godot\" in the machine's PATH.
	var previous_godot: String = OS.get_environment("GODOT")
	OS.set_environment("GODOT", OS.get_executable_path())
	var output: Array = []
	var code: int = OS.execute("bash", [script, "--dry-run", "--pack-only"], output, true)
	if previous_godot.is_empty():
		OS.unset_environment("GODOT")
	else:
		OS.set_environment("GODOT", previous_godot)
	var text: String = String(output[0])
	assert_eq(code, 0, "--dry-run ends well: %s" % text)
	assert_true(text.contains("--export-pack"), "with --pack-only it exports packs")
	assert_true(text.contains(CLIENT_PRESET.replace(" ", "\\ ")) and text.contains(SERVER_PRESET.replace(" ", "\\ ")),
			"it shows the two presets")
	var bad: Array = []
	assert_eq(OS.execute("bash", [script, "--opcion-inventada"], bad, true), 1, "an unknown option gives an error")
	var help: Array = []
	assert_eq(OS.execute("bash", [script, "--help"], help, true), 0)
	assert_true(String(help[0]).contains("--pack-only"), "the help documents the options")


# --- A real pack ------------------------------------------------------------------------------

func test_the_server_pack_exports_trimmed_and_without_development_folders() -> void:
	var out: String = ProjectSettings.globalize_path(PACK_PATH)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--export-pack", SERVER_PRESET, out])
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	if not assert_true(pid > 0, "the export process launches"):
		return
	var waited: float = 0.0
	while OS.is_process_running(pid) and waited < PACK_TIMEOUT_SECONDS:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	if OS.is_process_running(pid):
		OS.kill(pid)
		fail("the pack export took more than %d s" % int(PACK_TIMEOUT_SECONDS))
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "the export ends well")
	if not assert_true(FileAccess.file_exists(PACK_PATH), "the pack is created"):
		return
	var zip: ZIPReader = ZIPReader.new()
	if not assert_eq(zip.open(out), OK, "the pack opens"):
		return
	var files: PackedStringArray = zip.get_files()
	var total: int = 0
	for file_name: String in files:
		total += zip.read_file(file_name).size()
	zip.close()
	for dir: String in FORBIDDEN_DIRS + ["scenes/tests/"]:
		for file_name: String in files:
			if file_name.begins_with(dir):
				fail("the pack carries %s" % file_name)
				break
	for required: String in ["project.binary", "addons/terrain_3d/terrain.gdextension",
			"addons/terrain_3d/LICENSE.txt", "assets/LICENSES.md",
			"scenes/world/zones/vado_gris/vado_gris.tscn.remap",
			"scenes/world/zones/vado_gris/terrain/terrain3d_00_00.res",
			"scenes/server/server_main.tscn.remap", "scripts/server/zone_server.gd.remap",
			"data/characters/appearance_catalog.tres.remap", "data/progression/level_curve.tres.remap",
			"data/items/weapon/sword_shield_vado.tres.remap", "data/items/consumable/potion_health.tres.remap"]:
		assert_true(files.has(required), "the pack carries %s" % required)
	assert_true(files.size() > 500, "and it is not empty (%d files)" % files.size())
	# Stripped: the full project export exceeds 80 MB; the server is around 17.
	assert_true(total < 35 * 1024 * 1024, "the server pack is small (%d MB)" % roundi(float(total) / 1048576.0))
