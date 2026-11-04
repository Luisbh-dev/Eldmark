extends SceneTree
## Generates the global interface theme (UI-02): builds the [Theme] with [UIThemeBuilder] (which reads
## the palette from [UIPalette]) and saves it to [code]assets/ui/theme/eldmark_theme.tres[/code].
##
## If the chosen fonts are already in [code]assets/fonts/[/code] (Noto Sans and Cinzel; see
## [constant UIThemeBuilder.BODY_FONT_PATH] and [constant UIThemeBuilder.TITLE_FONT_PATH]) it
## wires them into the theme; if not, the theme uses the engine's. It must be run again whenever
## the palette, the builder or the fonts change:
##
## [codeblock]
## godot --headless --path . -s res://tools/ui/build_theme.gd
## [/codeblock]
## Exits with code 1 if it cannot save the file.


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
