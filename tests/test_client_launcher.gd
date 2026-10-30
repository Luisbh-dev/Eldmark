extends TestCase
## Pruebas de [ClientLauncher], el nodo que elige el modo de cliente (sandbox, red o enjambre) que
## [code]boot.gd[/code] monta por la ruta de su escena (para que el servidor dedicado no cargue los
## scripts del cliente). Los modos de red y el enjambre los ejercitan las pruebas de procesos
## ([code]test_net_harness.gd[/code]); aquí, el sandbox en un proceso de verdad y el enlace entre los
## dos scripts.

const BootScript = preload("res://scripts/boot.gd")
const LAUNCHER_SCENE: String = "res://scenes/client/client_launcher.tscn"


func test_boot_and_launcher_agree_on_the_parser_metadata_and_the_scene() -> void:
	assert_eq(BootScript.CLIENT_PARSER_META, ClientLauncher.PARSER_META,
			"boot.gd no puede nombrar ClientLauncher, así que repite el nombre del metadato")
	assert_eq(BootScript.CLIENT_LAUNCHER_SCENE, LAUNCHER_SCENE)
	var packed: PackedScene = load(LAUNCHER_SCENE) as PackedScene
	assert_not_null(packed, "la escena del lanzador carga")
	var launcher: Node = packed.instantiate()
	assert_true(launcher is ClientLauncher, "y su raíz es el lanzador")
	launcher.free()


func test_the_scenes_the_launcher_switches_to_exist() -> void:
	for path: String in [ClientLauncher.CLIENT_MAIN_SCENE, ClientLauncher.ONLINE_MAIN_SCENE,
			ClientLauncher.SWARM_SCENE, ClientLauncher.FRONT_MAIN_SCENE]:
		assert_true(ResourceLoader.exists(path), "existe %s" % path)


## El sandbox, arrancado como el proyecto (escena principal, sin ventana): boot.gd monta el lanzador, éste
## interpreta los argumentos con la función de boot.gd (avisos incluidos) y cambia a la escena del sandbox.
func test_the_sandbox_starts_through_the_launcher_and_reports_unknown_options() -> void:
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", "60", "--",
			"--zone=no_existe", "--realm=solmarch", "--opcion-inventada"])
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = String(output[0]) if not output.is_empty() else ""
	assert_eq(code, 0, "el proceso del sandbox termina bien: %s" % text.right(600))
	assert_true(text.contains("Zona desconocida 'no_existe'"), "avisa de la zona desconocida: %s" % text)
	assert_true(text.contains("Argumento desconocido: --opcion-inventada"), "y del argumento")
	assert_true(text.contains("Sin pantalla (headless): arrancando el cliente"), "y arranca el cliente")
	assert_false(text.contains("SCRIPT ERROR"), "sin errores de script: %s" % text)


## El título con cuenta (docs/plataforma.md §5.5), arrancado como el proyecto con [code]--title --platform[/code] hacia
## un puerto donde no escucha nadie: monta FrontMain sin errores y dice que no hay conexión con el servidor.
func test_the_title_starts_through_the_launcher_without_a_platform() -> void:
	var port: int = NetHarness.free_udp_port()
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", "180", "--",
			"--title", "--platform=http://127.0.0.1:%d" % port])
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = String(output[0]) if not output.is_empty() else ""
	assert_eq(code, 0, "el proceso del título termina bien: %s" % text.right(600))
	assert_true(text.contains("Plataforma http://127.0.0.1:%d: Sin conexión con el servidor" % port),
			"pide el estado y no hay servidor: %s" % text.right(600))
	assert_false(text.contains("SCRIPT ERROR"), "sin errores de script: %s" % text)
	assert_false(text.contains("ERROR:"), "ni del motor: %s" % text.right(600))
