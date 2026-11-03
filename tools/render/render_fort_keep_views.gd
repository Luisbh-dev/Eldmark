extends SceneTree
## Herramienta de revisión del fuerte: carga una escena (por defecto la vista previa del torreón
## nuevo) y guarda las vistas a altura de jugador que rodean al fuerte, con la cámara real del
## juego ([CameraRig], por encima del hombro) sobre un objetivo a 1,6 m de los pies, como en
## el recorrido del banco de calidad (build/calidad/mundo/jugador_*). No hay personaje en la
## imagen: solo la cámara.
##
## Necesita ventana (no headless). Uso desde la raíz del proyecto:
## [codeblock]
## godot --path . --resolution 1920x1080 -s res://tools/render/render_fort_keep_views.gd -- \
##     --out=C:/ruta/build/torreon/despues
## [/codeblock]
## Opciones: [code]--scene=res://...tscn[/code] (por defecto la vista previa; con
## [code]res://scenes/world/zones/vado_gris/vado_gris.tscn[/code] salen las vistas "antes"),
## [code]--realm=eldrun|vardheim|solmarch[/code] (paleta del torreón),
## [code]--only=<prefijo>[/code] (una sola vista, por el prefijo de su nombre),
## [code]--shadow-quality=N[/code] (filtro de sombras suaves de la luz direccional, 0 a 5; por defecto el del proyecto).
## Posiciones y ángulos: los de las vistas de Vardheim del banco de calidad.

const DEFAULT_SCENE: String = "res://scenes/tests/fort_keep_preview.tscn"
const CAMERA_RIG_SCENE: PackedScene = preload("res://scenes/client/camera_rig.tscn")
## Altura del objetivo de la cámara sobre los pies (CameraTarget de PlayerCharacter).
const HEAD_HEIGHT: float = 1.6
## Fotogramas de espera tras colocar la cámara (sombras, LOD y el clipmap del terreno).
const SETTLE_FRAMES: int = 30

## [nombre, x, y (pies), z, yaw en grados, pitch en grados]. El índice del banco de calidad
## da la posición real del jugador y el yaw con el que miraba.
const VIEWS: Array = [
	["01_campamento_spawn", 0.0, 6.2, -138.0, 180.0, 0.0],
	["06_camino_hacia_el_puente", 0.0, 5.6, -105.0, 180.0, -2.0],
	["09_puente_entrada", 0.0, 4.1, -76.0, 180.0, 0.0],
	["10_puente_centro", 0.0, 5.5, -62.0, 180.0, 6.0],
	["11_puente_desde_la_orilla", 22.0, 4.7, -86.0, 150.0, 0.0],
	["13_ladera_del_fuerte", 0.0, 4.3, -44.0, 180.0, 6.0],
	["14_fuerte_esquina_exterior", -32.0, 5.4, -32.0, -135.0, 8.0],
	["15_fuerte_puerta_lejos", -38.0, 5.5, 0.0, -90.0, 6.0],
	["16_fuerte_puerta_cerca", -27.0, 9.9, 0.0, -90.0, 12.0],
	["17_fuerte_patio", -12.0, 10.1, -9.0, -127.0, 6.0],
	["18_fuerte_torre", 9.0, 10.3, 10.0, 42.0, 22.0],
	["19_fuerte_circulo_de_captura", -8.0, 10.2, 7.0, -90.0, 6.0],
	["20_fuerte_patio_hacia_la_puerta", 13.0, 10.3, -9.0, 125.0, 4.0],
	["21_fuerte_pasarela", -19.0, 13.6, -8.0, 90.0, 4.0],
	["22_fuerte_rampa_norte", 8.0, 10.8, -12.0, 90.0, 8.0],
	["23_vado_orilla_este", -44.0, 4.0, -4.0, 90.0, 2.0],
	["24_vado_centro", -62.0, 2.7, 0.0, 90.0, 3.0],
	["25_vado_desde_el_oeste", -80.0, 4.0, 0.0, -90.0, 3.0],
	["31_capilla", 28.0, 9.7, -2.0, -90.0, 6.0],
	["32_franja_central_arboles_muertos", 40.0, 5.8, -22.0, 90.0, 2.0],
]

var _out_dir: String = ""
var _scene_path: String = DEFAULT_SCENE
var _realm: String = ""
var _only: String = ""
var _shadow_quality: int = -1


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=").replace("\\", "/")
		elif arg.begins_with("--scene="):
			_scene_path = arg.trim_prefix("--scene=")
		elif arg.begins_with("--realm="):
			_realm = arg.trim_prefix("--realm=")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")
		elif arg.begins_with("--shadow-quality="):
			_shadow_quality = int(arg.trim_prefix("--shadow-quality="))
	if _out_dir.is_empty():
		_out_dir = ProjectSettings.globalize_path("res://build/torreon")
	_run()


func _run() -> void:
	await process_frame
	if DisplayServer.get_name() == "headless":
		printerr("Esta herramienta necesita ventana: ejecútala sin --headless.")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(_out_dir)
	if _shadow_quality >= 0:
		RenderingServer.directional_soft_shadow_filter_set_quality(_shadow_quality as RenderingServer.ShadowQuality)

	var packed: PackedScene = load(_scene_path) as PackedScene
	if packed == null:
		printerr("No se pudo cargar %s" % _scene_path)
		quit(1)
		return
	var zone: Node = packed.instantiate()
	root.add_child(zone)
	if not _realm.is_empty() and zone is FortKeepPreview:
		(zone as FortKeepPreview).apply_realm(StringName(_realm))
	var rig: CameraRig = CAMERA_RIG_SCENE.instantiate() as CameraRig
	root.add_child(rig)
	rig.set_scripted_look(true)
	var target := Node3D.new()
	target.name = "ObjetivoCamara"
	root.add_child(target)

	for view: Array in VIEWS:
		var view_name: String = view[0]
		if not _only.is_empty() and not view_name.begins_with(_only):
			continue
		target.global_position = Vector3(float(view[1]), float(view[2]) + HEAD_HEIGHT, float(view[3]))
		rig.set_target(target)
		rig.set_look(deg_to_rad(float(view[4])), deg_to_rad(float(view[5])))
		for _i: int in SETTLE_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		var path: String = _out_dir.path_join("%s.png" % view_name)
		var error: Error = image.save_png(path)
		print("%s -> %s (%s)" % [view_name, path, error_string(error)])
	quit(0)
