class_name UIGallery
extends Control
## Galería de la interfaz (UI-02, UI-09): una página que muestra todos los estilos del tema global y
## los componentes comunes, para revisarlos de un vistazo y para que las pruebas comprueben que no
## falta ninguno.
## [br][br]
## Se abre con la escena [code]scenes/tests/ui_gallery.tscn[/code] (herramienta de desarrollo, solo
## cliente):
## [codeblock]
## godot --path . res://scenes/tests/ui_gallery.tscn
## [/codeblock]
## Todo se monta en código desde [method _ready]. Sobre un fondo de color plano (para que se vea la
## translucidez de los paneles) hay una sección por tipo de control del tema ([UIThemeBuilder]):
## etiquetas, botones, interruptores, barras, campos de texto, deslizadores, pestañas, listas,
## paneles, ventanas y diálogos, los emblemas y colores de bando, las rarezas y los componentes
## comunes de UI-09. Los tipos que el motor muestra bajo demanda (tooltip, menús emergentes, ventana
## y diálogo) tienen un control que los abre: pasar el ratón por «Pasa el ratón», el menú y el
## desplegable, y el botón «Abrir diálogo».

## Tipos del tema que el motor dibuja solo bajo demanda y que la galería abre con un control (ver
## la documentación de la clase), así que no hay un nodo de ese tipo visible en la página.
const ON_DEMAND_TYPES: Array[StringName] = [
	&"TooltipPanel", &"TooltipLabel", &"PopupMenu", &"PopupPanel", &"Window", &"AcceptDialog",
]
## Color del fondo de la galería: un verde de prado apagado, como el mundo detrás del HUD.
const BACKGROUND_COLOR: Color = Color(0.2, 0.27, 0.24, 1.0)

var _content: VBoxContainer = null
var _dialog: AcceptDialog = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var background: ColorRect = ColorRect.new()
	background.name = "Background"
	background.color = BACKGROUND_COLOR
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)
	var margin: MarginContainer = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	scroll.add_child(margin)
	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 18)
	margin.add_child(_content)

	var title: Label = Label.new()
	title.text = "Galería de la interfaz de Eldmark"
	title.theme_type_variation = &"TitleLabel"
	_content.add_child(title)

	_build_labels()
	_build_buttons()
	_build_bars()
	_build_text_fields()
	_build_sliders()
	_build_tabs_and_lists()
	_build_panels()
	_build_windows()
	_build_factions()
	_build_extra_sections()


## Todos los nodos de la galería (para las pruebas).
func get_all_controls() -> Array[Control]:
	var result: Array[Control] = []
	for node: Node in find_children("*", "Control", true, false):
		result.append(node as Control)
	return result


## true si la galería enseña el tipo de tema [param type]: hay un control de esa clase o con esa
## variación de tema, o es uno de los que el motor abre bajo demanda ([constant ON_DEMAND_TYPES]).
func shows_theme_type(type: StringName) -> bool:
	if ON_DEMAND_TYPES.has(type):
		return true
	for control: Control in get_all_controls():
		if control.theme_type_variation == type or control.is_class(String(type)):
			return true
	return false


## Diálogo de ejemplo (para las pruebas: abrirlo y cerrarlo).
func get_dialog() -> AcceptDialog:
	return _dialog


# --- Secciones --------------------------------------------------------------------------------

func _build_labels() -> void:
	var row: Container = _section("Etiquetas")
	var samples: Array[Array] = [
		[&"", "Etiqueta normal"], [&"TitleLabel", "Título"], [&"HeaderLabel", "Encabezado"],
		[&"DimLabel", "Texto secundario"], [&"WarningLabel", "Aviso"], [&"ErrorLabel", "Error"],
		[&"HintLabel", "Alt: liberar cursor · V: cambiar hombro"],
		[&"DebugLabel", "FPS: 144 · 1234,56 m"],
	]
	for sample: Array in samples:
		var label: Label = Label.new()
		label.text = sample[1]
		label.theme_type_variation = sample[0]
		row.add_child(label)
	var rich: RichTextLabel = RichTextLabel.new()
	rich.bbcode_enabled = true
	rich.fit_content = true
	rich.custom_minimum_size = Vector2(360.0, 0.0)
	rich.text = "Texto [b]enriquecido[/b] con [color=#E9C341]color[/color] y [i]cursiva[/i]."
	row.add_child(rich)


func _build_buttons() -> void:
	var row: Container = _section("Botones")
	row.add_child(_button("Normal"))
	var disabled: Button = _button("Desactivado")
	disabled.disabled = true
	row.add_child(disabled)
	var toggle: Button = _button("Alternar")
	toggle.toggle_mode = true
	toggle.button_pressed = true
	row.add_child(toggle)
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var button: Button = _button(RealmCatalog.display_name(faction_id))
		button.theme_type_variation = UIThemeBuilder.variation_name("Button", faction_id)
		row.add_child(button)
	var danger: Button = _button("Peligro")
	danger.theme_type_variation = &"DangerButton"
	row.add_child(danger)
	var ghost: Button = _button("Fantasma")
	ghost.theme_type_variation = &"GhostButton"
	row.add_child(ghost)
	var check: CheckBox = CheckBox.new()
	check.text = "Casilla"
	check.button_pressed = true
	row.add_child(check)
	var switch: CheckButton = CheckButton.new()
	switch.text = "Interruptor"
	row.add_child(switch)
	var option: OptionButton = OptionButton.new()
	for item: String in ["Bajo", "Medio", "Alto"]:
		option.add_item(item)
	option.select(1)
	row.add_child(option)
	var menu: MenuButton = MenuButton.new()
	menu.text = "Menú"
	menu.get_popup().add_item("Invitar")
	menu.get_popup().add_item("Susurrar")
	menu.get_popup().add_separator()
	menu.get_popup().add_item("Ignorar")
	row.add_child(menu)
	var tip: Button = _button("Pasa el ratón")
	tip.tooltip_text = "Texto de ayuda del motor, con el estilo del tema."
	row.add_child(tip)


func _build_bars() -> void:
	var row: Container = _section("Barras")
	row.add_child(_bar(&"", 60.0))
	row.add_child(_bar(&"HealthBar", 75.0))
	row.add_child(_bar(&"StaminaBar", 40.0))
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		row.add_child(_bar(UIThemeBuilder.variation_name("Bar", faction_id), 50.0))


func _build_text_fields() -> void:
	var row: Container = _section("Campos de texto")
	var line: LineEdit = LineEdit.new()
	line.text = "Ana"
	line.custom_minimum_size = Vector2(180.0, 0.0)
	row.add_child(line)
	var placeholder: LineEdit = LineEdit.new()
	placeholder.placeholder_text = "Nombre del personaje"
	placeholder.custom_minimum_size = Vector2(200.0, 0.0)
	row.add_child(placeholder)
	var read_only: LineEdit = LineEdit.new()
	read_only.text = "Solo lectura"
	read_only.editable = false
	read_only.custom_minimum_size = Vector2(160.0, 0.0)
	row.add_child(read_only)
	var area: TextEdit = TextEdit.new()
	area.text = "Texto de varias líneas.\nSegunda línea."
	area.custom_minimum_size = Vector2(240.0, 70.0)
	row.add_child(area)
	var spin: SpinBox = SpinBox.new()
	spin.value = 24.0
	row.add_child(spin)


func _build_sliders() -> void:
	var row: Container = _section("Deslizadores")
	var horizontal: HSlider = HSlider.new()
	horizontal.value = 60.0
	horizontal.custom_minimum_size = Vector2(220.0, 0.0)
	row.add_child(horizontal)
	var vertical: VSlider = VSlider.new()
	vertical.value = 40.0
	vertical.custom_minimum_size = Vector2(0.0, 90.0)
	row.add_child(vertical)


func _build_tabs_and_lists() -> void:
	var row: Container = _section("Pestañas, listas y desplazamiento")
	var tabs: TabContainer = TabContainer.new()
	tabs.custom_minimum_size = Vector2(300.0, 110.0)
	for tab_name: String in ["Gráficos", "Audio", "Cámara"]:
		var page: Label = Label.new()
		page.name = tab_name
		page.text = "Contenido de «%s»" % tab_name
		tabs.add_child(page)
	row.add_child(tabs)
	var bar: TabBar = TabBar.new()
	for tab_title: String in ["Uno", "Dos", "Tres"]:
		bar.add_tab(tab_title)
	row.add_child(bar)
	var list: ItemList = ItemList.new()
	list.custom_minimum_size = Vector2(160.0, 100.0)
	for item: String in ["Vado Gris", "Isenholm", "Valcorin", "Kassar"]:
		list.add_item(item)
	list.select(1)
	row.add_child(list)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(180.0, 100.0)
	var tall: Label = Label.new()
	tall.text = "Un texto muy largo que obliga a desplazarse\nlínea\nlínea\nlínea\nlínea\nlínea\nlínea"
	scroll.add_child(tall)
	row.add_child(scroll)
	row.add_child(VSeparator.new())
	var separated: VBoxContainer = VBoxContainer.new()
	var above: Label = Label.new()
	above.text = "Encima"
	separated.add_child(above)
	separated.add_child(HSeparator.new())
	var below: Label = Label.new()
	below.text = "Debajo"
	separated.add_child(below)
	row.add_child(separated)


func _build_panels() -> void:
	var row: Container = _section("Paneles")
	var variations: Array[StringName] = [&"", &"InsetPanel", &"WindowPanel", &"DebugPanel"]
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		variations.append(UIThemeBuilder.variation_name("Panel", faction_id))
	for variation: StringName in variations:
		var panel: PanelContainer = PanelContainer.new()
		panel.theme_type_variation = variation
		var label: Label = Label.new()
		label.text = "Panel" if variation == &"" else String(variation)
		panel.add_child(label)
		row.add_child(panel)
	var plain: Panel = Panel.new()
	plain.custom_minimum_size = Vector2(90.0, 40.0)
	row.add_child(plain)


func _build_windows() -> void:
	var row: Container = _section("Ventanas y diálogos")
	_dialog = AcceptDialog.new()
	_dialog.title = "Diálogo del motor"
	_dialog.dialog_text = "Así se ve una ventana incrustada con el tema."
	_dialog.exclusive = false
	_dialog.visible = false
	add_child(_dialog)
	var open: Button = _button("Abrir diálogo")
	open.pressed.connect(func() -> void: _dialog.popup_centered())
	row.add_child(open)


func _build_factions() -> void:
	var row: Container = _section("Bandos y rarezas")
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var column: VBoxContainer = VBoxContainer.new()
		column.name = "Bando%s" % String(faction_id).capitalize()
		var emblem: TextureRect = TextureRect.new()
		emblem.name = "Emblema"
		emblem.texture = UIPalette.load_emblem(faction_id)
		emblem.custom_minimum_size = Vector2(72.0, 72.0)
		emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		column.add_child(emblem)
		var label: Label = Label.new()
		label.text = RealmCatalog.display_name(faction_id)
		label.add_theme_color_override(&"font_color", UIPalette.faction_color(faction_id))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(label)
		row.add_child(column)
	for rarity: int in UIPalette.RARITY_COLORS.size():
		var swatch: PanelContainer = PanelContainer.new()
		swatch.name = "Rareza%d" % rarity
		var style: StyleBoxFlat = StyleBoxFlat.new()
		style.bg_color = UIPalette.INSET_BG
		style.border_color = UIPalette.rarity_color(rarity)
		style.set_border_width_all(2)
		style.set_corner_radius_all(3)
		style.set_content_margin_all(8.0)
		swatch.add_theme_stylebox_override(&"panel", style)
		var label: Label = Label.new()
		label.text = UIPalette.rarity_name(rarity)
		label.add_theme_color_override(&"font_color", UIPalette.rarity_color(rarity))
		swatch.add_child(label)
		row.add_child(swatch)


## Hueco para las secciones de los componentes comunes (UI-09).
func _build_extra_sections() -> void:
	pass


# --- Utilidades -------------------------------------------------------------------------------

# Añade una sección con título y devuelve el contenedor en el que se ponen sus muestras.
func _section(title: String) -> Container:
	var box: VBoxContainer = VBoxContainer.new()
	box.name = title
	box.add_theme_constant_override("separation", 8)
	var header: Label = Label.new()
	header.text = title
	header.theme_type_variation = &"HeaderLabel"
	box.add_child(header)
	var row: HFlowContainer = HFlowContainer.new()
	row.name = "Muestras"
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 10)
	box.add_child(row)
	_content.add_child(box)
	return row


func _button(text: String) -> Button:
	var button: Button = Button.new()
	button.text = text
	return button


func _bar(variation: StringName, value: float) -> ProgressBar:
	var bar: ProgressBar = ProgressBar.new()
	bar.theme_type_variation = variation
	bar.value = value
	bar.custom_minimum_size = Vector2(180.0, 22.0)
	return bar
