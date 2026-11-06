extends TestCase
## Tests of [BuildInfo]: the id format, the baked revision file, the "dev" fallback, that the client and the zone
## report the same id, and that the build id stays out of the simulation hash.

const TEMP_PATH: String = "user://test_build_info_revision.txt"


func after_each() -> void:
	if FileAccess.file_exists(TEMP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))


func _write(text: String) -> void:
	var file: FileAccess = FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func test_compose_format() -> void:
	assert_eq(BuildInfo.compose("0.1.0", 7, "a1b2c3d"), "eldmark-0.1.0-p7+a1b2c3d")
	assert_eq(BuildInfo.compose("0.1.0", 7, "v1.2-3-gabc1234-dirty"), "eldmark-0.1.0-p7+v1.2-3-gabc1234-dirty")
	assert_eq(BuildInfo.compose("1 2", 7, "x"), "eldmark-1_2-p7+x", "spaces in the version become underscores")


func test_compose_limits_length_and_cleans_revision() -> void:
	assert_eq(BuildInfo.compose("0.1.0", 7, "a b;c"), "eldmark-0.1.0-p7+abc", "odd characters are dropped")
	assert_eq(BuildInfo.compose("0.1.0", 7, "x".repeat(200)).length(), BuildInfo.MAX_LENGTH)
	assert_eq(BuildInfo.compose("0.1.0", 7, ""), "eldmark-0.1.0-p7+dev", "an empty revision is dev")


func test_read_revision_from_file() -> void:
	assert_eq(BuildInfo.read_revision("user://no_such_revision_file.txt"), "dev", "no file is dev")
	_write("abc1234-dirty\n")
	assert_eq(BuildInfo.read_revision(TEMP_PATH), "abc1234-dirty")
	_write("  \n")
	assert_eq(BuildInfo.read_revision(TEMP_PATH), "dev", "an empty file is dev")
	_write("first\nsecond\n")
	assert_eq(BuildInfo.read_revision(TEMP_PATH), "first", "only the first line counts")


func test_build_id_has_version_protocol_and_revision() -> void:
	var id: String = BuildInfo.build_id()
	var version: String = str(ProjectSettings.get_setting("application/config/version", "0"))
	assert_true(id.begins_with("eldmark-%s-p%d+" % [version, NetProtocol.PROTOCOL_VERSION]), id)
	assert_true(id.ends_with("+" + BuildInfo.revision()), id)
	assert_true(id.length() <= BuildInfo.MAX_LENGTH)
	# The baked file is git-ignored: in the editor and in the tests there is none, so the id is the dev one.
	if not FileAccess.file_exists(BuildInfo.BAKED_PATH):
		assert_eq(BuildInfo.revision(), BuildInfo.DEV_REVISION)


func test_client_and_zone_report_the_same_id() -> void:
	assert_eq(PlatformApi.build_id(), BuildInfo.build_id())
	assert_eq(ZonePlatform.build_id(), BuildInfo.build_id())


func test_build_id_does_not_enter_the_sim_hash() -> void:
	var source: String = FileAccess.get_file_as_string("res://scripts/shared/net/net_protocol.gd")
	assert_true(source.contains("func compute_sim_hash"), "the hash function is where this test expects it")
	assert_false(source.contains("BuildInfo"), "NetProtocol never reads the build id")


func test_the_reports_of_the_client_and_the_swarm_carry_the_build_id() -> void:
	for path: String in ["res://scripts/client/net_client.gd", "res://scripts/client/bot_swarm.gd",
			"res://scripts/client/online_main.gd", "res://scripts/server/zone_server.gd"]:
		assert_true(FileAccess.get_file_as_string(path).contains("BuildInfo.build_id()"), "%s reports the build id" % path)
