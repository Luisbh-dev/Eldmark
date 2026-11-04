extends RefCounted
## Banco de capturas de calidad (TEC-50), área interfaz (escenario de online_driver.gd).
##
## Galería de la interfaz (scenes/tests/ui_gallery.tscn): una captura por pantalla de contenido al desplazar el scroll.

var d: Variant


func run(drv: Variant) -> void:
	d = drv
	await d.wait(2.0)
	var scroll: ScrollContainer = d.main.get_node_or_null(^"Scroll") as ScrollContainer
	if scroll == null:
		d.note("la galería no tiene nodo Scroll")
		await d.shot("interfaz/galeria_ui_00.png", "galería de la interfaz", "scenes/tests/ui_gallery.tscn")
		return
	var page: int = int(scroll.size.y * 0.9)
	var total: int = int(scroll.get_v_scroll_bar().max_value)
	var n: int = 0
	var pos: int = 0
	while pos <= total and n < 14:
		scroll.scroll_vertical = pos
		await d.wait(0.4)
		await d.shot("interfaz/galeria_ui_%02d.png" % n, "galería de la interfaz (estilos del tema y componentes), pantalla %d (desplazamiento %d de %d)" % [n + 1, pos, total],
				"scenes/tests/ui_gallery.tscn con el scroll movido por script")
		n += 1
		pos += page
