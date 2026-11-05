extends SceneTree
## Bakes a zone's top-down map without a GPU (docs/fortress.md, section 6; UI-20) and saves it to
## [code]assets/maps/<zone>.png[/code] together with its scale and its fixed places in
## [code]assets/maps/<zone>_map.tres[/code] ([ZoneMapDefinition], as text).
##
## Usage (from the project root, without a window; a few seconds):
## [codeblock]
## godot --headless --path . -s res://tools/bake_zone_map.gd
## godot --headless --path . -s res://tools/bake_zone_map.gd -- --zone=vado_gris --out=user://mapa.png
## godot --headless --path . --import      # afterwards, to import the new PNG
## [/codeblock]
## What is drawn and how: [ZoneMapBaker]. It is deterministic (same scene, same map). It must be repeated
## if the zone's relief, water or collisions change; tests/test_zone_map.gd checks it.
## With [code]--out=[/code] the image and the resource go to that path (without touching those in [code]assets/maps/[/code]).
## [b]It is no longer the game's map (UI-51)[/b]: Vado Gris's is the parchment one from
## [code]tools/map/bake_parchment_map.gd[/code]. Without [code]--out=[/code] this tool would overwrite it with the old dump.

## Chunk of world and image size for each zone: northwest corner, size (m) and side (px). Vado
## Gris covers the playable area (300 x 300 m) with a 10 m margin, at 3.2 pixels per meter.
const ZONE_BAKES: Dictionary = {
	&"vado_gris": {"origin": Vector2(-160.0, -160.0), "size": Vector2(320.0, 320.0), "pixels": 1024},
}


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var zone_id: StringName = Zones.DEFAULT_ZONE
	var output_image: String = ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--zone="):
			zone_id = StringName(argument.trim_prefix("--zone="))
		elif argument.begins_with("--out="):
			output_image = argument.trim_prefix("--out=")
	if not Zones.has_zone(zone_id) or not ZONE_BAKES.has(zone_id):
		printerr("Zona sin horneado de mapa: «%s» (hay: %s)" % [zone_id, ", ".join(ZONE_BAKES.keys())])
		quit(1)
		return
	var started: int = Time.get_ticks_msec()
	var scene_path: String = Zones.get_scene_path(zone_id)
	print("Cargando %s..." % scene_path)
	var zone: Node3D = (load(scene_path) as PackedScene).instantiate() as Node3D
	root.add_child(zone)
	await physics_frame
	await physics_frame
	var bake: Dictionary = ZONE_BAKES[zone_id]
	var pixels: int = int(bake["pixels"])
	var definition: ZoneMapDefinition = ZoneMapBaker.build_definition(zone, zone_id,
			bake["origin"], bake["size"], Vector2i(pixels, pixels))
	var definition_path: String = ZoneMapDefinition.definition_path(zone_id)
	if not output_image.is_empty():
		definition.image_path = output_image
		definition_path = output_image.get_basename() + ZoneMapDefinition.DEFINITION_SUFFIX
	print("Horneando %d x %d px (%.2f m por píxel)..." % [pixels, pixels, definition.meters_per_pixel()])
	var image: Image = ZoneMapBaker.bake(zone, definition)
	if image == null:
		printerr("La zona no tiene un Terrain3D con datos: no se guarda nada")
		quit(1)
		return
	var directory: String = definition.image_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var error: Error = image.save_png(definition.image_path)
	if error != OK:
		printerr("No se pudo guardar %s (%s)" % [definition.image_path, error_string(error)])
		quit(1)
		return
	error = ResourceSaver.save(definition, definition_path)
	if error != OK:
		printerr("No se pudo guardar %s (%s)" % [definition_path, error_string(error)])
		quit(1)
		return
	print("%s (%.2f MB) y %s: %d lugares fijos, en %.1f s" % [definition.image_path,
			FileAccess.get_file_as_bytes(definition.image_path).size() / 1048576.0, definition_path,
			definition.landmarks.size(), (Time.get_ticks_msec() - started) / 1000.0])
	quit(0)
