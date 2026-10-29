extends TestCase
## Pruebas de la configuración de exportación (TEC-12): los dos presets de [code]export_presets.cfg[/code]
## (cliente Windows y servidor dedicado Linux), que sus filtros dejan fuera [code]build/[/code],
## [code]docs/[/code], [code]tests/[/code] y [code]platform/[/code] (el servicio en Go, que Godot ni
## escanea por su [code].gdignore[/code]) sin quitar nada de lo que el juego carga, que los
## scripts [code]tools/export.sh[/code] y [code]tools/export.ps1[/code] usan los mismos presets, y,
## en un proceso aparte, que exportar el paquete del servidor ([code]--export-pack[/code], que no necesita
## las plantillas de exportación) da un paquete recortado, con lo que hace falta y sin lo que sobra.
## [br][br]
## Exportar de verdad (el ejecutable) necesita las plantillas de exportación 4.7.2, que no se pueden
## instalar desde las pruebas: eso se hace a mano con [code]tools/export.sh[/code] (ver el README).

const PRESETS_PATH: String = "res://export_presets.cfg"
const CLIENT_PRESET: String = "Cliente Windows"
const SERVER_PRESET: String = "Servidor Linux"
const SCRIPT_SH: String = "res://tools/export.sh"
const SCRIPT_PS1: String = "res://tools/export.ps1"
## Carpetas que ningún paquete debe llevar.
const FORBIDDEN_DIRS: Array[String] = ["build/", "docs/", "tests/", "tools/", "exports/", ".github/", "platform/"]
## Carpetas y archivos que el juego carga y que ningún filtro puede quitar.
const REQUIRED_PATHS: Array[String] = [
	"project.godot", "default_bus_layout.tres", "export_presets.cfg",
	"scripts/boot.gd", "scripts/shared/player_character.gd", "scripts/server/zone_server.gd",
	"scripts/client/client_main.gd", "scenes/boot.tscn", "scenes/server/server_main.tscn",
	"scenes/client/client_main.tscn", "scenes/ui/hud.tscn",
	"scenes/world/zones/vado_gris/vado_gris.tscn", "data/combat/combat_rules.tres",
	"assets/ui/theme/eldmark_theme.tres", "assets/emblems/vardheim.svg",
	"addons/terrain_3d/terrain.gdextension", "addons/terrain_3d/LICENSE.txt",
	"addons/proton_scatter/LICENSE", "assets/LICENCIAS.md",
]
const PACK_PATH: String = "res://build/export_test/server_pack.zip"
## Segundos máximos de espera al proceso que exporta (la fase de una prueba admite 30).
const PACK_TIMEOUT_SECONDS: float = 26.0

var _presets: ConfigFile = ConfigFile.new()


func before_each() -> void:
	assert_eq(_presets.load(PRESETS_PATH), OK, "export_presets.cfg se lee como archivo de ajustes")


func after_each() -> void:
	if FileAccess.file_exists(PACK_PATH):
		DirAccess.remove_absolute(PACK_PATH)


# El preset con el nombre dado ("preset.0", "preset.1"...).
func _section_of(preset_name: String) -> String:
	for section: String in _presets.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and _presets.get_value(section, "name", "") == preset_name:
			return section
	return ""


func _value(section: String, key: String) -> Variant:
	return _presets.get_value(section, key, null)


# Patrones de exclusión de un preset, ya separados.
func _excludes(section: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for pattern: String in String(_value(section, "exclude_filter")).split(","):
		if not pattern.strip_edges().is_empty():
			result.append(pattern.strip_edges())
	return result


# true si algún patrón de [param patterns] (con comodines * y ?) encaja con [param path].
func _matches_any(path: String, patterns: PackedStringArray) -> bool:
	for pattern: String in patterns:
		if path.match(pattern):
			return true
	return false


# --- Los presets ------------------------------------------------------------------------------

func test_there_are_exactly_the_two_presets() -> void:
	var names: Array[String] = []
	for section: String in _presets.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			names.append(String(_presets.get_value(section, "name")))
			assert_true(_presets.has_section(section + ".options"), "%s tiene sus opciones" % section)
	names.sort()
	assert_eq(names, [CLIENT_PRESET, SERVER_PRESET] as Array[String])


func test_the_client_preset_is_windows_x86_64() -> void:
	var section: String = _section_of(CLIENT_PRESET)
	if not assert_false(section.is_empty(), "existe el preset del cliente"):
		return
	assert_eq(_value(section, "platform"), "Windows Desktop")
	assert_eq(_value(section, "dedicated_server"), false, "el cliente no es un servidor dedicado")
	assert_eq(_value(section, "export_filter"), "all_resources", "el cliente lleva todos los recursos")
	assert_eq(_presets.get_value(section + ".options", "binary_format/architecture"), "x86_64")
	assert_eq(_presets.get_value(section + ".options", "binary_format/embed_pck"), false,
			"el .pck va aparte, junto al ejecutable")
	assert_eq(_presets.get_value(section + ".options", "texture_format/s3tc_bptc"), true,
			"texturas comprimidas para el escritorio")
	assert_true(String(_value(section, "export_path")).begins_with("exports/windows/"))
	assert_true(String(_value(section, "export_path")).ends_with(".exe"))


func test_the_server_preset_is_a_dedicated_linux_x86_64_server() -> void:
	var section: String = _section_of(SERVER_PRESET)
	if not assert_false(section.is_empty(), "existe el preset del servidor"):
		return
	assert_eq(_value(section, "platform"), "Linux")
	assert_eq(_value(section, "dedicated_server"), true, "exportación como servidor dedicado")
	assert_eq(_value(section, "export_filter"), "customized", "con recorte de recursos por carpeta")
	assert_eq(_presets.get_value(section + ".options", "binary_format/architecture"), "x86_64")
	assert_eq(_presets.get_value(section + ".options", "texture_format/s3tc_bptc"), true,
			"las texturas del terreno (Terrain3D las valida) se exportan comprimidas")
	assert_true(String(_value(section, "export_path")).begins_with("exports/server/"))
	assert_false(String(_value(section, "export_path")).ends_with(".exe"))
	# Recorte: la capa visual fuera, pero nunca «remove» (las escenas de zona referencian modelos,
	# materiales y animaciones y el servidor no podría cargarlas).
	var files: Dictionary = _value(section, "customized_files")
	for visual_dir: String in ["res://assets/models/", "res://assets/materials/",
			"res://assets/audio/", "res://assets/animations/"]:
		assert_eq(files.get(visual_dir), "strip", "%s se recorta" % visual_dir)
	for path: String in files:
		assert_eq(files[path], "strip", "%s: solo se recorta, nunca se quita" % path)
		assert_false(path.begins_with("res://scripts") or path.begins_with("res://scenes")
				or path.begins_with("res://data"), "%s: el recorte no toca código, escenas ni datos" % path)
	assert_false(files.has("res://assets/textures/"),
			"las texturas del terreno no se recortan: Terrain3D registraría errores al cargarlas")


func test_both_presets_keep_the_development_folders_out_but_the_licences_in() -> void:
	for preset_name: String in [CLIENT_PRESET, SERVER_PRESET]:
		var section: String = _section_of(preset_name)
		var excludes: PackedStringArray = _excludes(section)
		for dir: String in FORBIDDEN_DIRS:
			assert_true(_matches_any(dir + "algo.txt", excludes), "%s excluye %s" % [preset_name, dir])
			assert_true(_matches_any(dir + "sub/archivo.gd", excludes), "%s excluye %s en profundidad" % [preset_name, dir])
		assert_true(_matches_any("scenes/tests/ui_gallery.tscn", excludes), "y las escenas de desarrollo")
		var includes: PackedStringArray = PackedStringArray()
		for pattern: String in String(_value(section, "include_filter")).split(","):
			includes.append(pattern.strip_edges())
		for licence: String in ["addons/terrain_3d/LICENSE.txt", "addons/proton_scatter/LICENSE",
				"assets/LICENCIAS.md"]:
			assert_true(_matches_any(licence, includes), "%s lleva %s (la MIT lo exige)" % [preset_name, licence])
			assert_true(FileAccess.file_exists("res://" + licence), "existe %s" % licence)


func test_no_filter_removes_what_the_game_loads() -> void:
	for preset_name: String in [CLIENT_PRESET, SERVER_PRESET]:
		var excludes: PackedStringArray = _excludes(_section_of(preset_name))
		for path: String in REQUIRED_PATHS:
			assert_true(FileAccess.file_exists("res://" + path), "existe %s" % path)
			assert_false(_matches_any(path, excludes), "%s no excluye %s" % [preset_name, path])
		# Todas las escenas de zona y los scripts que cargan cliente y servidor.
		for zone_id: StringName in Zones.get_zone_ids():
			var scene: String = Zones.get_scene_path(zone_id).trim_prefix("res://")
			assert_false(_matches_any(scene, excludes), "%s no excluye la zona %s" % [preset_name, zone_id])
		for dir: String in ["scripts/client", "scripts/server", "scripts/shared", "scripts/world"]:
			for file_name: String in DirAccess.get_files_at("res://" + dir):
				assert_false(_matches_any(dir + "/" + file_name, excludes),
						"%s no excluye %s/%s" % [preset_name, dir, file_name])
	# El filtro de pruebas no es tan amplio como para quitar nada más: la comprobación detecta lo que
	# sí debe quedar fuera.
	var sample: PackedStringArray = _excludes(_section_of(SERVER_PRESET))
	assert_true(_matches_any("tests/test_case.gd", sample))
	assert_true(_matches_any("docs/social.md", sample))
	assert_true(_matches_any("platform/internal/migrate/migrations/0001_accounts.up.sql", sample))
	assert_false(_matches_any("scripts/client/audio/audio_director.gd", sample))


func test_exports_are_not_tracked() -> void:
	var ignore: String = FileAccess.get_file_as_string("res://.gitignore")
	assert_true(ignore.contains("/exports/"), "lo exportado no se versiona")
	assert_true(ignore.contains("/build/"))


func test_godot_does_not_scan_the_platform_service() -> void:
	# platform/ es el servicio en Go (docs/plataforma.md §2.1): Godot no lo importa ni lo exporta.
	assert_true(FileAccess.file_exists("res://platform/.gdignore"), "platform/ lleva .gdignore")
	assert_true(FileAccess.file_exists("res://platform/go.mod"), "y es el módulo de Go")


# --- Los scripts de exportación ---------------------------------------------------------------

func test_the_export_scripts_use_the_presets_and_their_paths() -> void:
	var server_out: String = String(_value(_section_of(SERVER_PRESET), "export_path"))
	var client_out: String = String(_value(_section_of(CLIENT_PRESET), "export_path"))
	for path: String in [SCRIPT_SH, SCRIPT_PS1]:
		assert_true(FileAccess.file_exists(path), "existe %s" % path)
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.contains("'%s'" % CLIENT_PRESET) or text.contains("\"%s\"" % CLIENT_PRESET),
				"%s usa el preset «%s»" % [path, CLIENT_PRESET])
		assert_true(text.contains("'%s'" % SERVER_PRESET) or text.contains("\"%s\"" % SERVER_PRESET),
				"%s usa el preset «%s»" % [path, SERVER_PRESET])
		assert_true(text.contains(server_out), "%s escribe el servidor en %s" % [path, server_out])
		assert_true(text.contains(client_out), "%s escribe el cliente en %s" % [path, client_out])
		assert_true(text.contains("--export-pack"), "%s admite exportar solo el paquete" % path)
		assert_true(text.contains("export_templates"), "%s comprueba las plantillas de exportación" % path)
		assert_true(text.contains("lfs pull"), "%s avisa si faltan los objetos de LFS" % path)
		assert_true(text.contains("--headless"), "%s exporta sin ventana" % path)
		assert_true(text.contains("run-server.sh"), "%s deja el lanzador del servidor" % path)
	var shell: String = FileAccess.get_file_as_string(SCRIPT_SH)
	assert_true(shell.begins_with("#!/usr/bin/env bash"), "export.sh es un script de bash")
	assert_false(shell.contains("\r"), "con finales de línea LF")
	# PowerShell 5.1 lee como ANSI un .ps1 sin BOM: con tildes necesita la marca UTF-8.
	var ps_bytes: PackedByteArray = FileAccess.get_file_as_bytes(SCRIPT_PS1)
	assert_true(ps_bytes.size() > 3 and ps_bytes[0] == 0xEF and ps_bytes[1] == 0xBB and ps_bytes[2] == 0xBF,
			"export.ps1 lleva la marca UTF-8 (BOM)")


func test_the_shell_script_is_valid_and_dry_runs() -> void:
	if OS.get_name() == "Windows":
		return
	var script: String = ProjectSettings.globalize_path(SCRIPT_SH)
	if not FileAccess.file_exists(SCRIPT_SH) or OS.execute("bash", ["--version"], []) != 0:
		return
	var syntax: Array = []
	assert_eq(OS.execute("bash", ["-n", script], syntax, true), 0, "export.sh es sintácticamente correcto: %s" % [syntax])
	assert_true((FileAccess.get_unix_permissions(SCRIPT_SH) & FileAccess.UNIX_EXECUTE_OWNER) != 0, "export.sh es ejecutable")
	# El script busca Godot en GODOT o en el PATH; se le da el que ejecuta la prueba para no depender
	# de que haya un «godot» en el PATH de la máquina.
	var previous_godot: String = OS.get_environment("GODOT")
	OS.set_environment("GODOT", OS.get_executable_path())
	var output: Array = []
	var code: int = OS.execute("bash", [script, "--dry-run", "--pack-only"], output, true)
	if previous_godot.is_empty():
		OS.unset_environment("GODOT")
	else:
		OS.set_environment("GODOT", previous_godot)
	var text: String = String(output[0])
	assert_eq(code, 0, "--dry-run termina bien: %s" % text)
	assert_true(text.contains("--export-pack"), "con --pack-only exporta paquetes")
	assert_true(text.contains(CLIENT_PRESET.replace(" ", "\\ ")) and text.contains(SERVER_PRESET.replace(" ", "\\ ")),
			"muestra los dos presets")
	var bad: Array = []
	assert_eq(OS.execute("bash", [script, "--opcion-inventada"], bad, true), 1, "una opción desconocida da error")
	var help: Array = []
	assert_eq(OS.execute("bash", [script, "--help"], help, true), 0)
	assert_true(String(help[0]).contains("--pack-only"), "la ayuda documenta las opciones")


# --- Un paquete de verdad ---------------------------------------------------------------------

func test_the_server_pack_exports_trimmed_and_without_development_folders() -> void:
	var out: String = ProjectSettings.globalize_path(PACK_PATH)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--export-pack", SERVER_PRESET, out])
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	if not assert_true(pid > 0, "se lanza el proceso de exportación"):
		return
	var waited: float = 0.0
	while OS.is_process_running(pid) and waited < PACK_TIMEOUT_SECONDS:
		await tree.create_timer(0.25).timeout
		waited += 0.25
	if OS.is_process_running(pid):
		OS.kill(pid)
		fail("la exportación del paquete tardó más de %d s" % int(PACK_TIMEOUT_SECONDS))
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "la exportación termina bien")
	if not assert_true(FileAccess.file_exists(PACK_PATH), "se crea el paquete"):
		return
	var zip: ZIPReader = ZIPReader.new()
	if not assert_eq(zip.open(out), OK, "el paquete se abre"):
		return
	var files: PackedStringArray = zip.get_files()
	var total: int = 0
	for file_name: String in files:
		total += zip.read_file(file_name).size()
	zip.close()
	for dir: String in FORBIDDEN_DIRS + ["scenes/tests/"]:
		for file_name: String in files:
			if file_name.begins_with(dir):
				fail("el paquete lleva %s" % file_name)
				break
	for required: String in ["project.binary", "addons/terrain_3d/terrain.gdextension",
			"addons/terrain_3d/LICENSE.txt", "assets/LICENCIAS.md",
			"scenes/world/zones/vado_gris/vado_gris.tscn.remap",
			"scenes/world/zones/vado_gris/terrain/terrain3d_00_00.res",
			"scenes/server/server_main.tscn.remap", "scripts/server/zone_server.gd.remap"]:
		assert_true(files.has(required), "el paquete lleva %s" % required)
	assert_true(files.size() > 500, "y no está vacío (%d archivos)" % files.size())
	# Recortado: la exportación completa del proyecto pasa de los 80 MB; el servidor ronda los 17.
	assert_true(total < 35 * 1024 * 1024, "el paquete del servidor es pequeño (%d MB)" % roundi(float(total) / 1048576.0))
