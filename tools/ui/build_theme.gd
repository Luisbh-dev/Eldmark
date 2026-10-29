extends SceneTree
## Genera el tema global de la interfaz (UI-02): construye el [Theme] con [UIThemeBuilder] (que lee
## la paleta de [UIPalette]) y lo guarda en [code]assets/ui/theme/eldmark_theme.tres[/code].
##
## Si las fuentes elegidas ya están en [code]assets/fonts/[/code] (Noto Sans y Cinzel; ver
## [constant UIThemeBuilder.BODY_FONT_PATH] y [constant UIThemeBuilder.TITLE_FONT_PATH]) las
## cablea en el tema; si no, el tema usa la del motor. Hay que volver a ejecutarlo cada vez que
## cambie la paleta, el constructor o las fuentes:
##
## [codeblock]
## godot --headless --path . -s res://tools/ui/build_theme.gd
## [/codeblock]
## Sale con código 1 si no puede guardar el archivo.


func _initialize() -> void:
	var theme: Theme = UIThemeBuilder.build_with_project_fonts()
	DirAccess.make_dir_recursive_absolute(UIThemeBuilder.THEME_PATH.get_base_dir())
	var error: Error = ResourceSaver.save(theme, UIThemeBuilder.THEME_PATH)
	if error != OK:
		push_error("No se pudo guardar %s (%s)" % [UIThemeBuilder.THEME_PATH, error_string(error)])
		quit(1)
		return
	print("Tema guardado en %s" % UIThemeBuilder.THEME_PATH)
	quit(0)
