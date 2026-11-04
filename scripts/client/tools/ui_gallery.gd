class_name UIGallery
extends Control
## UI gallery (UI-02, UI-09): a page that shows all the styles of the global theme and the common
## components, to review them at a glance and so that the tests verify none is missing.
## [br][br]
## It opens with the scene [code]scenes/tests/ui_gallery.tscn[/code] (development tool, client only):
## [codeblock]
## godot --path . res://scenes/tests/ui_gallery.tscn
## [/codeblock]
## Everything is assembled in code from [method _ready]. Over a flat color background (so the
## translucency of the panels shows) there is one section per control type in the theme
## ([UIThemeBuilder]): labels, buttons, toggles, bars, text fields, sliders, tabs, lists, panels, windows
## and dialogs, the faction emblems and colors, the rarities and the common components of UI-09. The
## types the engine shows on demand (tooltip, popup menus, window and dialog) have a control that opens
## them: hovering over "Pasa el ratón" (Hover here), the menu and the dropdown, and the "Abrir diálogo"
## (Open dialog) button.

## Theme types that the engine only draws on demand and that the gallery opens with a control (see the
## class documentation), so there is no node of that type visible on the page.
const ON_DEMAND_TYPES: Array[StringName] = [
	&"TooltipPanel", &"TooltipLabel", &"PopupMenu", &"PopupPanel", &"Window", &"AcceptDialog",
]
## Gallery background color: a muted meadow green, like the world behind the HUD.
const BACKGROUND_COLOR: Color = Color(0.2, 0.27, 0.24, 1.0)

var _content: VBoxContainer = null
var _dialog: AcceptDialog = null
var _tooltip: UITooltip = null
var _confirm: UIConfirmDialog = null
var _confirm_result: Label = null
var _cooldown_slot: UIIconSlot = null
var _slots: Array[UIIconSlot] = []


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
	UISounds.hook_all(self)


## All the gallery's nodes (for the tests).
func get_all_controls() -> Array[Control]:
	var result: Array[Control] = []
	for node: Node in find_children("*", "Control", true, false):
		result.append(node as Control)
	return result


## true if the gallery shows theme type [param type]: there is a control of that class or with that theme
## variation, or it is one of those the engine opens on demand ([constant ON_DEMAND_TYPES]).
func shows_theme_type(type: StringName) -> bool:
	if ON_DEMAND_TYPES.has(type):
		return true
	for control: Control in get_all_controls():
		if control.theme_type_variation == type or control.is_class(String(type)):
			return true
	return false


## Sample dialog (for the tests: open it and close it).
func get_dialog() -> AcceptDialog:
	return _dialog


# --- Sections ---------------------------------------------------------------------------------

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


## The gallery's tooltip (its own, not the shared one).
func get_ui_tooltip() -> UITooltip:
	return _tooltip


## The gallery's confirmation dialog.
func get_confirm_dialog() -> UIConfirmDialog:
	return _confirm


## The gallery's icon slots.
func get_slots() -> Array[UIIconSlot]:
	return _slots


## Slot that repeats a cooldown endlessly.
func get_cooldown_slot() -> UIIconSlot:
	return _cooldown_slot


# --- Common components (UI-09) ----------------------------------------------------------------

func _build_extra_sections() -> void:
	# Own layer for the tooltip and confirmation dialog: they live in the gallery (not in the shared ones)
	# so they disappear with it.
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "ComponentLayer"
	layer.layer = UITooltip.LAYER
	add_child(layer)
	_tooltip = UITooltip.new()
	layer.add_child(_tooltip)
	_confirm = UIConfirmDialog.new()
	layer.add_child(_confirm)
	_build_slots()
	_build_glyphs()
	_build_confirmation()
	_build_focus_grid()


func _build_slots() -> void:
	var row: Container = _section("Casillas de icono, rarezas y reutilización")
	var icons: Array[Texture2D] = []
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		icons.append(UIPalette.load_emblem(faction_id))
	for rarity: int in UIPalette.RARITY_COLORS.size():
		var slot: UIIconSlot = _slot(icons[rarity % icons.size()], rarity)
		slot.set_tooltip_info(UIPalette.rarity_name(rarity) + ": objeto de ejemplo",
				"Cuerpo con [b]BBCode[/b] y [color=#E9C341]color[/color]. Un texto algo más largo "
				+ "para que el tooltip se ajuste en varias líneas.", "Arma · una mano")
		slot.bind_tooltip(_tooltip)
		row.add_child(slot)
	var stack: UIIconSlot = _slot(icons[0], UIPalette.Rarity.COMMON)
	stack.count = 20
	row.add_child(stack)
	var bound: UIIconSlot = _slot(icons[1], -1)
	bound.key_action = &"ability_1"
	bound.start_cooldown(6.0)
	bound.cooldown_finished.connect(func() -> void:
		await get_tree().create_timer(1.2).timeout
		if is_instance_valid(bound):
			bound.start_cooldown(6.0))
	_cooldown_slot = bound
	row.add_child(bound)
	var disabled: UIIconSlot = _slot(icons[2], -1)
	disabled.enabled = false
	row.add_child(disabled)
	var chosen: UIIconSlot = _slot(icons[3], UIPalette.Rarity.RARE)
	chosen.selected = true
	chosen.key_action = &"primary_attack"
	row.add_child(chosen)
	row.add_child(_slot(null, -1))


func _build_glyphs() -> void:
	var row: Container = _section("Glifos de tecla y línea de ayuda")
	for action: StringName in [&"move_forward", &"jump", &"sprint", &"dodge", &"primary_attack",
			&"block", &"ability_1", &"interact", &"free_cursor", &"toggle_cursor", &"open_settings"]:
		var pair: HBoxContainer = HBoxContainer.new()
		pair.add_theme_constant_override("separation", 6)
		pair.add_child(UIKeyGlyph.for_action(action))
		var label: Label = Label.new()
		label.text = String(action)
		label.theme_type_variation = &"DimLabel"
		pair.add_child(label)
		row.add_child(pair)
	var bar: UIHintBar = UIHintBar.new()
	row.add_child(bar)


func _build_confirmation() -> void:
	var row: Container = _section("Diálogo de confirmación")
	_confirm_result = Label.new()
	_confirm_result.theme_type_variation = &"DimLabel"
	_confirm_result.text = "Sin respuesta"
	var normal: Button = _button("Confirmar una acción")
	normal.pressed.connect(func() -> void:
		_confirm.open("Salir de la zona", "¿Quieres volver al campamento?", "Volver", "Quedarme"))
	row.add_child(normal)
	var danger: Button = _button("Borrar personaje")
	danger.theme_type_variation = &"DangerButton"
	danger.pressed.connect(func() -> void:
		_confirm.open("Borrar personaje", "Esta acción no se puede deshacer.", "Borrar", "Cancelar",
				true))
	row.add_child(danger)
	_confirm.confirmed.connect(func() -> void: _confirm_result.text = "Confirmado")
	_confirm.canceled.connect(func() -> void: _confirm_result.text = "Cancelado")
	row.add_child(_confirm_result)


func _build_focus_grid() -> void:
	var row: Container = _section("Foco navegable (flechas o Tab)")
	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	row.add_child(grid)
	var controls: Array[Control] = []
	for index: int in 5:
		var slot: UIIconSlot = _slot(UIPalette.load_emblem(RealmCatalog.FACTION_IDS[index % 4]), -1)
		grid.add_child(slot)
		controls.append(slot)
	UIFocus.grid(controls, 3)
	var buttons: HBoxContainer = HBoxContainer.new()
	var button_row: Array[Control] = []
	for text: String in ["Uno", "Dos", "Tres"]:
		var button: Button = _button(text)
		buttons.add_child(button)
		button_row.append(button)
	UIFocus.chain_horizontal(button_row)
	row.add_child(buttons)


func _slot(icon: Texture2D, rarity: int) -> UIIconSlot:
	var slot: UIIconSlot = UIIconSlot.new()
	slot.icon = icon
	slot.rarity = rarity
	_slots.append(slot)
	return slot


# --- Utilities --------------------------------------------------------------------------------

# Adds a titled section and returns the container into which its samples are put.
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
