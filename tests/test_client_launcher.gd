extends TestCase
## Tests for [ClientLauncher], the node that picks the client mode (sandbox, network or swarm) that
## [code]boot.gd[/code] mounts through its scene path (so the dedicated server does not load the
## client scripts). The network modes and the swarm are exercised by the process tests
## ([code]test_net_harness.gd[/code]); here, the sandbox in a real process and the link between the
## two scripts.

const BootScript = preload("res://scripts/boot.gd")
const LAUNCHER_SCENE: String = "res://scenes/client/client_launcher.tscn"


func test_boot_and_launcher_agree_on_the_parser_metadata_and_the_scene() -> void:
	assert_eq(BootScript.CLIENT_PARSER_META, ClientLauncher.PARSER_META,
			"boot.gd cannot name ClientLauncher, so it repeats the name of the metadata")
	assert_eq(BootScript.CLIENT_LAUNCHER_SCENE, LAUNCHER_SCENE)
	var packed: PackedScene = load(LAUNCHER_SCENE) as PackedScene
	assert_not_null(packed, "the launcher scene loads")
	var launcher: Node = packed.instantiate()
	assert_true(launcher is ClientLauncher, "and its root is the launcher")
	launcher.free()


func test_the_scenes_the_launcher_switches_to_exist() -> void:
	for path: String in [ClientLauncher.CLIENT_MAIN_SCENE, ClientLauncher.ONLINE_MAIN_SCENE,
			ClientLauncher.SWARM_SCENE, ClientLauncher.FRONT_MAIN_SCENE]:
		assert_true(ResourceLoader.exists(path), "%s exists" % path)


## The sandbox, started like the project (main scene, no window): boot.gd mounts the launcher, which
## interprets the arguments with boot.gd's function (warnings included) and switches to the sandbox scene.
func test_the_sandbox_starts_through_the_launcher_and_reports_unknown_options() -> void:
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", "60", "--",
			"--zone=no_existe", "--realm=solmarch", "--opcion-inventada"])
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = String(output[0]) if not output.is_empty() else ""
	assert_eq(code, 0, "the sandbox process ends well: %s" % text.right(600))
	assert_true(text.contains("Zona desconocida 'no_existe'"), "it warns about the unknown zone: %s" % text)
	assert_true(text.contains("Argumento desconocido: --opcion-inventada"), "and about the argument")
	assert_true(text.contains("Sin pantalla (headless): arrancando el cliente"), "and starts the client")
	assert_false(text.contains("SCRIPT ERROR"), "without script errors: %s" % text)


## The title screen with an account (docs/platform.md §5.5), started like the project with [code]--title --platform[/code] towards
## a port where nobody is listening: it mounts FrontMain without errors and says there is no connection to the server.
## [br]On Linux the rejection of the closed port is noticed instantly; on Windows, Godot does not detect it
## (the [StreamPeerTCP] stays in \"connecting\") and the call only fails when its deadline runs out
## ([constant PlatformApi.TIMEOUT_S], 15 s of game clock). With [code]--fixed-fps[/code] each
## frame counts as 1/60 s for those timers, so 1200 frames (20 s of game time) cover the
## deadline on any machine and without depending on how fast the process runs.
## [br]The text is read from the process log ([code]--log-file[/code], always UTF-8) and not from what
## [method OS.execute] returns: on Windows the latter decodes the output with the system code page
## and \"conexión\" arrives as \"conexiÃ³n\".
func test_the_title_starts_through_the_launcher_without_a_platform() -> void:
	var port: int = NetHarness.free_udp_port()
	var log_path: String = NetHarness.build_path("title_without_platform.log")
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--fixed-fps", "60",
			"--quit-after", "1200", "--", "--title", "--platform=http://127.0.0.1:%d" % port])
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = FileAccess.get_file_as_string(log_path)
	assert_eq(code, 0, "the title screen process ends well: %s" % text.right(600))
	assert_true(text.contains("Plataforma http://127.0.0.1:%d: Sin conexión con el servidor" % port),
			"it asks for the status and there is no server: %s" % text.right(600))
	assert_false(text.contains("SCRIPT ERROR"), "without script errors: %s" % text)
	assert_false(text.contains("ERROR:"), "nor engine errors: %s" % text.right(600))
