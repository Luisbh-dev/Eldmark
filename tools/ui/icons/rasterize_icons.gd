extends SceneTree
## Rasteriza los SVG de los iconos de la interfaz (ART-12) a PNG con el rasterizador del propio motor.
## Uso (el tamaño es el lado en píxeles; el SVG es de 128 x 128):
##   godot --headless --path . -s res://tools/ui/icons/rasterize_icons.gd -- <carpeta_svg> <carpeta_png> [lado]
## Sin argumentos lee assets/ui/icons y escribe assets/ui/icons/png a 128 px.

const SVG_SIDE: float = 128.0


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var src: String = args[0] if args.size() > 0 else "res://assets/ui/icons"
	var dst: String = args[1] if args.size() > 1 else "res://assets/ui/icons/png"
	var side: int = int(args[2]) if args.size() > 2 else 128
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst))
	var failed: int = 0
	var done: int = 0
	var files: PackedStringArray = DirAccess.get_files_at(src)
	files.sort()
	for file: String in files:
		if file.get_extension() != "svg":
			continue
		var text: String = FileAccess.get_file_as_string(src.path_join(file))
		var image := Image.new()
		var error: Error = image.load_svg_from_string(text, float(side) / SVG_SIDE)
		if error != OK:
			push_error("No se pudo rasterizar %s (%d)" % [file, error])
			failed += 1
			continue
		image.save_png(dst.path_join(file.get_basename() + ".png"))
		done += 1
	print("rasterizados %d iconos a %d px en %s" % [done, side, dst])
	quit(1 if failed > 0 else 0)
