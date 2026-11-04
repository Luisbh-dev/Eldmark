extends SceneTree
## Rasterises the SVG layers of the interface icons (ART-12) with the engine's own rasteriser (ThorVG).
## It walks a whole folder, subfolders included, and leaves a PNG next to each SVG at the
## size declared by its `width` (the SVG carries the side in pixels: 256 for the large icons, 4 times
## the final size for the small ones).
## Usage:
##   godot --headless --path . -s res://tools/ui/icons/rasterize_icons.gd -- <layers_folder>
## Without arguments it uses res://build/iconos/capas.


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var root: String = args[0] if args.size() > 0 else "res://build/iconos/capas"
	var counts: Dictionary = {"done": 0, "failed": 0}
	_walk(root, counts)
	print("rasterizadas %d capas en %s (%d fallos)" % [counts["done"], root, counts["failed"]])
	quit(1 if int(counts["failed"]) > 0 else 0)


func _walk(dir: String, counts: Dictionary) -> void:
	for sub: String in DirAccess.get_directories_at(dir):
		_walk(dir.path_join(sub), counts)
	for file: String in DirAccess.get_files_at(dir):
		if file.get_extension() != "svg":
			continue
		var text: String = FileAccess.get_file_as_string(dir.path_join(file))
		var image := Image.new()
		var error: Error = image.load_svg_from_string(text, 1.0)
		if error != OK:
			push_error("No se pudo rasterizar %s (%d)" % [dir.path_join(file), error])
			counts["failed"] = int(counts["failed"]) + 1
			continue
		image.save_png(dir.path_join(file.get_basename() + ".png"))
		counts["done"] = int(counts["done"]) + 1
