extends SceneTree
## Hornea el mapa cenital de una zona sin GPU (docs/fuerte.md, sección 6; UI-20) y lo guarda en
## [code]assets/maps/<zona>.png[/code] (por Git LFS) junto a su escala y sus lugares fijos en
## [code]assets/maps/<zona>_map.tres[/code] ([ZoneMapDefinition], en texto).
##
## Uso (desde la raíz del proyecto, sin ventana; unos segundos):
## [codeblock]
## godot --headless --path . -s res://tools/bake_zone_map.gd
## godot --headless --path . -s res://tools/bake_zone_map.gd -- --zone=vado_gris --out=user://mapa.png
## godot --headless --path . --import      # después, para importar el PNG nuevo
## [/codeblock]
## Qué se dibuja y cómo: [ZoneMapBaker]. Es determinista (misma escena, mismo mapa). Hay que repetirlo
## si cambia el relieve, el agua o las colisiones de la zona; lo comprueba tests/test_zone_map.gd.
## Con [code]--out=[/code] la imagen y el recurso van a esa ruta (sin tocar los de [code]assets/maps/[/code]).
## [b]Ya no es el mapa del juego (UI-51)[/b]: el del Vado Gris es el de pergamino de
## [code]tools/map/bake_parchment_map.gd[/code]. Sin [code]--out=[/code] esta herramienta lo pisaría con el volcado antiguo.

## Trozo de mundo y tamaño de la imagen de cada zona: esquina noroeste, tamaño (m) y lado (px). El Vado
## Gris cubre el área jugable (300 x 300 m) con 10 m de margen, a 3,2 píxeles por metro.
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
