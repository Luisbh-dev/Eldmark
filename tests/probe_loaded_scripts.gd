extends SceneTree
## Proceso auxiliar de [code]test_architecture.gd[/code] (no es una prueba: el ejecutor solo descubre
## [code]test_*.gd[/code]). Carga [code]res://scripts/boot.gd[/code], el script de la escena principal
## que ejecuta también el servidor dedicado (y con él todo lo que sus referencias de clase arrastran),
## e imprime, para cada ruta que reciba como argumento de usuario (tras [code]--[/code]), una línea
## [code]CACHED <ruta> true|false[/code] según haya quedado cargada en el proceso.


func _initialize() -> void:
	load("res://scripts/boot.gd")
	for path: String in OS.get_cmdline_user_args():
		print("CACHED %s %s" % [path, str(ResourceLoader.has_cached(path)).to_lower()])
	quit(0)
