extends SceneTree
## Hornea el mapa de pergamino de una zona (UI-51) con [ParchmentMapBaker] y lo guarda en
## [code]assets/maps/<zona>_parchment.png[/code] (por Git LFS) junto a su escala y sus lugares fijos en
## [code]assets/maps/<zona>_parchment_map.tres[/code] ([ZoneMapDefinition], en texto).
##
## Uso (desde la raíz del proyecto, sin ventana; unos minutos a 2048 px):
## [codeblock]
## godot --headless --path . -s res://tools/map/bake_parchment_map.gd
## godot --headless --path . -s res://tools/map/bake_parchment_map.gd -- --size=1024 --out=user://prueba.png
## godot --headless --path . --import      # después, para importar el PNG nuevo
## [/codeblock]
## Con [code]--out=[/code] la imagen y el recurso van a esa ruta (sin tocar los de [code]assets/maps/[/code]) y
## con [code]--size=[/code] la imagen es más pequeña (para probar: todo se escala con los metros).
## No toca [code]assets/maps/<zona>.png[/code] ni [code]<zona>_map.tres[/code]: el mapa que usa el juego sigue
## siendo el de [code]tools/bake_zone_map.gd[/code] hasta que se decida cambiarlo.

## Trozo de mundo de cada zona: esquina noroeste y tamaño (m). El Vado Gris cubre ±256 m, así que entran
## las montañas que cierran el valle.
const ZONE_BAKES: Dictionary = {
	&"vado_gris": {"origin": Vector2(-256.0, -256.0), "size": Vector2(512.0, 512.0), "pixels": 2048},
}
const PARCHMENT_SUFFIX: String = "_parchment"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var zone_id: StringName = Zones.DEFAULT_ZONE
	var output_image: String = ""
	var pixels_override: int = 0
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--zone="):
			zone_id = StringName(argument.trim_prefix("--zone="))
		elif argument.begins_with("--out="):
			output_image = argument.trim_prefix("--out=")
		elif argument.begins_with("--size="):
			pixels_override = int(argument.trim_prefix("--size="))
	if not Zones.has_zone(zone_id) or not ZONE_BAKES.has(zone_id):
		printerr("Zona sin mapa de pergamino: «%s» (hay: %s)" % [zone_id, ", ".join(ZONE_BAKES.keys())])
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
	var pixels: int = pixels_override if pixels_override > 0 else int(bake["pixels"])
	var definition: ZoneMapDefinition = ZoneMapBaker.build_definition(zone, zone_id,
			bake["origin"], bake["size"], Vector2i(pixels, pixels))
	var image_path: String = "%s/%s%s%s" % [ZoneMapDefinition.MAP_DIR, String(zone_id), PARCHMENT_SUFFIX,
			ZoneMapDefinition.IMAGE_SUFFIX]
	var definition_path: String = "%s/%s%s%s" % [ZoneMapDefinition.MAP_DIR, String(zone_id), PARCHMENT_SUFFIX,
			ZoneMapDefinition.DEFINITION_SUFFIX]
	if not output_image.is_empty():
		image_path = output_image
		definition_path = output_image.get_basename() + ZoneMapDefinition.DEFINITION_SUFFIX
	definition.image_path = image_path
	print("Horneando %d x %d px (%.2f m por píxel)..." % [pixels, pixels, definition.meters_per_pixel()])
	var image: Image = ParchmentMapBaker.bake(zone, definition)
	if image == null:
		printerr("La zona no tiene un Terrain3D con datos: no se guarda nada")
		quit(1)
		return
	var directory: String = image_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var error: Error = image.save_png(image_path)
	if error != OK:
		printerr("No se pudo guardar %s (%s)" % [image_path, error_string(error)])
		quit(1)
		return
	error = ResourceSaver.save(definition, definition_path)
	if error != OK:
		printerr("No se pudo guardar %s (%s)" % [definition_path, error_string(error)])
		quit(1)
		return
	print("%s (%.2f MB) y %s, en %.1f s" % [image_path, FileAccess.get_file_as_bytes(image_path).size() / 1048576.0,
			definition_path, (Time.get_ticks_msec() - started) / 1000.0])
	quit(0)
