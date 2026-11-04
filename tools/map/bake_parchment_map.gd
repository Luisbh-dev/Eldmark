extends SceneTree
## Hornea el mapa de pergamino de una zona (UI-51) con [ParchmentMapBaker] y lo guarda como mapa de la zona: la
## imagen en [code]assets/maps/<zona>.png[/code] (por Git LFS) y su escala y sus lugares fijos en
## [code]assets/maps/<zona>_map.tres[/code] ([ZoneMapDefinition], en texto). Es el mapa que usan la ventana M y el
## minimapa, y lo comprueba [code]tests/test_zone_map.gd[/code].
##
## Orden única y reproducible (desde la raíz del proyecto, sin ventana; unos 40 s a 2048 px):
## [codeblock]
## godot --headless --path . -s res://tools/map/bake_parchment_map.gd
## godot --headless --path . --import      # después, para importar el PNG nuevo
## [/codeblock]
## Hay que repetirla cuando cambien el relieve, el agua, las murallas, el fuerte o la vegetación del Vado Gris (la
## prueba [code]test_baking_the_zone_again_gives_the_saved_map[/code] avisa si el mapa guardado ya no es el de la
## escena). Con [code]--out=[/code] la imagen y el recurso van a esa ruta (sin tocar los de [code]assets/maps/[/code]) y
## con [code]--size=[/code] la imagen es más pequeña (para probar: todo se escala con los metros).
## [br][br]
## El horneador anterior (volcado de la pintura del terreno, [code]tools/bake_zone_map.gd[/code]) queda solo como
## referencia: ya no escribe en [code]assets/maps/[/code] salvo que se le pida.
## [br][br]
## Los marcadores de la interfaz (fuerte, campamentos, puertas) caen en el mismo sitio en los dos mapas: el dibujo se
## hace con las coordenadas del mundo.

## Trozo de mundo de cada zona: esquina noroeste y tamaño (m). El Vado Gris cubre ±200 m: el valle jugable
## (±150 m) ocupa tres cuartos de la imagen y las montañas lo enmarcan sin comérselo.
const ZONE_BAKES: Dictionary = {
	&"vado_gris": {"origin": Vector2(-200.0, -200.0), "size": Vector2(400.0, 400.0), "pixels": 2048},
}
const PARCHMENT_SUFFIX: String = ""


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
