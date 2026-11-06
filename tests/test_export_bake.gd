extends TestCase
## The build id baked at export time (TEC-12): both presets include the git-ignored file, the export scripts bake
## it, and the helper they use prints the id the game itself reports.

const PRESETS_PATH: String = "res://export_presets.cfg"
const PRINT_SCRIPT: String = "res://tools/print_build_id.gd"
const EXPORT_SH: String = "res://tools/export.sh"
const EXPORT_PS1: String = "res://tools/export.ps1"


func test_both_presets_include_the_baked_file() -> void:
	var presets: ConfigFile = ConfigFile.new()
	assert_eq(presets.load(PRESETS_PATH), OK)
	var seen: int = 0
	for section: String in presets.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			var include: String = str(presets.get_value(section, "include_filter", ""))
			assert_true(include.contains(BuildInfo.BAKED_PATH.trim_prefix("res://")),
					"%s includes the baked build id file" % presets.get_value(section, "name", section))
			seen += 1
	assert_eq(seen, 2, "the two presets")


func test_the_baked_file_is_ignored_by_git() -> void:
	var ignore: String = FileAccess.get_file_as_string("res://.gitignore")
	assert_true(ignore.contains("/" + BuildInfo.BAKED_PATH.trim_prefix("res://")), ".gitignore lists the baked file")


func test_the_export_scripts_bake_and_ask_the_project_for_the_id() -> void:
	for path: String in [EXPORT_SH, EXPORT_PS1]:
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.contains("build_id.txt"), "%s writes build_id.txt" % path)
		assert_true(text.contains("print_build_id.gd"), "%s asks the project for the whole id" % path)
		assert_true(text.contains("ELDMARK_REVISION"), "%s lets the CI set the revision" % path)


func test_the_helper_prints_the_id_the_game_reports() -> void:
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "-s", PRINT_SCRIPT], output, true)
	assert_eq(code, 0, "the helper ends well")
	var found: String = ""
	for line: String in String(output[0]).split("\n"):
		if line.strip_edges().begins_with("BUILD_ID="):
			found = line.strip_edges().trim_prefix("BUILD_ID=")
	assert_eq(found, BuildInfo.build_id(), "same text as BuildInfo.build_id()")
