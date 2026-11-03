class_name UILayout
extends RefCounted
## Colocación de los elementos del HUD que van centrados arriba (UI-49): la brújula, el panel del fuerte y el aviso de
## derribado.
## [br][br]
## [b]Por qué existe.[/b] [code]set_anchors_and_offsets_preset(PRESET_CENTER_TOP, PRESET_MODE_MINSIZE)[/code] mide el
## tamaño mínimo del control al llamarlo y, si todavía no lo tiene (un control recién creado dentro de
## [code]_ready[/code]), deja los dos márgenes en 0: el control crece solo hacia la derecha y queda con su borde
## izquierdo en el centro de la pantalla. [method anchor_top_center] fija el ancho con márgenes simétricos y deja que
## crezca por los dos lados, así el centro queda en el centro de su padre en cualquier momento y con cualquier
## altura. Solo cliente.


## Ancla [param control] arriba al centro de su padre con [param width] px de ancho, a [param top] px del borde
## superior, centrado en horizontal y creciendo hacia abajo y hacia los dos lados.
static func anchor_top_center(control: Control, width: float, top: float) -> void:
	control.anchor_left = 0.5
	control.anchor_right = 0.5
	control.anchor_top = 0.0
	control.anchor_bottom = 0.0
	control.offset_left = -width * 0.5
	control.offset_right = width * 0.5
	control.offset_top = top
	control.offset_bottom = top
	control.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control.grow_vertical = Control.GROW_DIRECTION_END
