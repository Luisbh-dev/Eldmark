extends SceneTree
## Reduces textures to the maximum resolution allowed in the repo before copying them.
##
## Rules from docs/art.md and CLAUDE.md: no texture over 2048 px enters the repo (1024
## for small props). It halves with a box filter ([method Image.shrink_x2]) until
## the longer side does not exceed [code]--max[/code]; on normal maps, it also
## renormalizes each vector after averaging.
## [br][br]
## Usage (from the project root, with absolute paths or paths relative to the current directory):
## [codeblock]
## godot --headless --path . -s res://tools/assets/downscale_texture.gd -- \
##     --in=<source.png> --out=<destination.png> [--max=2048] [--normal]
## [/codeblock]

const DEFAULT_MAX_SIZE: int = 2048


func _initialize() -> void:
	var in_path: String = ""
	var out_path: String = ""
	var max_size: int = DEFAULT_MAX_SIZE
	var is_normal: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--in="):
			in_path = arg.trim_prefix("--in=")
		elif arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")
		elif arg.begins_with("--max="):
			max_size = arg.trim_prefix("--max=").to_int()
		elif arg == "--normal":
			is_normal = true
	if in_path.is_empty() or out_path.is_empty() or max_size <= 0:
		push_error("Uso: -- --in=<origen.png> --out=<destino.png> [--max=2048] [--normal]")
		quit(1)
		return

	var image: Image = Image.load_from_file(in_path)
	if image == null or image.is_empty():
		push_error("No se pudo leer %s" % in_path)
		quit(1)
		return
	var original: Vector2i = image.get_size()
	if image.is_compressed():
		image.decompress()
	while maxi(image.get_width(), image.get_height()) > max_size:
		image.shrink_x2()
	if is_normal:
		_renormalize(image)
	var error: Error = image.save_png(out_path)
	if error != OK:
		push_error("No se pudo guardar %s (%s)" % [out_path, error_string(error)])
		quit(1)
		return
	print("%s: %dx%d -> %dx%d" % [out_path.get_file(), original.x, original.y,
			image.get_width(), image.get_height()])
	quit(0)


## Renormalizes a normal map (RGB in [0, 1] -> vector in [-1, 1]).
func _renormalize(image: Image) -> void:
	if image.get_format() != Image.FORMAT_RGB8 and image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var channels: int = 3 if image.get_format() == Image.FORMAT_RGB8 else 4
	var data: PackedByteArray = image.get_data()
	for i: int in range(0, data.size(), channels):
		var n := Vector3(data[i] / 127.5 - 1.0, data[i + 1] / 127.5 - 1.0, data[i + 2] / 127.5 - 1.0)
		if n.length_squared() < 0.000001:
			continue
		n = n.normalized()
		data[i] = clampi(roundi((n.x + 1.0) * 127.5), 0, 255)
		data[i + 1] = clampi(roundi((n.y + 1.0) * 127.5), 0, 255)
		data[i + 2] = clampi(roundi((n.z + 1.0) * 127.5), 0, 255)
	image.set_data(image.get_width(), image.get_height(), image.has_mipmaps(), image.get_format(),
			data)
