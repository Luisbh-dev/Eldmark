class_name UIThemeBuilder
extends RefCounted
## Construye el [Theme] global de la interfaz (UI-02) a partir de [UIPalette].
## [br][br]
## El tema vive en [code]assets/ui/theme/eldmark_theme.tres[/code] (asignado en el proyecto con
## [code]gui/theme/custom[/code]) y lo genera [code]tools/ui/build_theme.gd[/code] llamando a
## [method build]; así el archivo y la paleta no se separan, y una prueba comprueba que el archivo
## guardado es el que sale de aquí. Para cambiar el aspecto se cambia la paleta o este script y se
## vuelve a generar, no el [code].tres[/code] a mano.
## [br][br]
## Estilo: minimalista oscuro y translúcido, bordes de metal con el borde superior más grueso (el
## remate) y acentos del color del bando. Tipos con estilo: [Panel], [PanelContainer], [Button],
## [Label], [ProgressBar], [LineEdit], [TextEdit], [CheckBox], [CheckButton], [HSlider], [VSlider],
## [TabContainer], [TabBar], [PopupMenu], [ItemList], las barras de desplazamiento, los separadores,
## el tooltip, [Window], [AcceptDialog] y [RichTextLabel].
## [br][br]
## [b]Variaciones[/b] (se aplican con [member Control.theme_type_variation]): de [Label]
## [code]TitleLabel[/code], [code]HeaderLabel[/code], [code]DimLabel[/code], [code]WarningLabel[/code],
## [code]ErrorLabel[/code], [code]HintLabel[/code] y [code]DebugLabel[/code]; de [PanelContainer]
## [code]DebugPanel[/code], [code]InsetPanel[/code], [code]WindowPanel[/code]; de [Button]
## [code]DangerButton[/code] y [code]GhostButton[/code]; de [ProgressBar] [code]HealthBar[/code] y
## [code]StaminaBar[/code]; y, por cada bando, [code]Panel<Bando>[/code], [code]Button<Bando>[/code] y
## [code]Bar<Bando>[/code] ([method variation_name]).
## [br][br]
## [b]Fuentes.[/b] Todavía no hay fuentes en el repositorio (assets/fonts/ está vacío): el tema usa
## la del motor. Las ranuras ya están preparadas: [param body_font] es la fuente por defecto del tema
## (Noto Sans, OFL) y [param title_font] la de [code]TitleLabel[/code], [code]HeaderLabel[/code] y las
## pestañas (Cinzel o Alegreya SC, OFL). Cuando los archivos estén en [constant BODY_FONT_PATH] y
## [constant TITLE_FONT_PATH], [code]tools/ui/build_theme.gd[/code] los carga y los cablea sola.
## [br][br]
## Solo cliente.

const THEME_PATH: String = "res://assets/ui/theme/eldmark_theme.tres"
## Dónde deben estar las fuentes elegidas (decisión del backlog: Noto Sans para el cuerpo y Cinzel o
## Alegreya SC para los títulos, todas OFL) cuando el usuario las añada.
const BODY_FONT_PATH: String = "res://assets/fonts/NotoSans-Variable.ttf"
const TITLE_FONT_PATH: String = "res://assets/fonts/Cinzel-Variable.ttf"

const FONT_SIZE: int = 16
const SMALL_FONT_SIZE: int = 14
const HEADER_FONT_SIZE: int = 20
const TITLE_FONT_SIZE: int = 26
const WINDOW_TITLE_HEIGHT: int = 32

const CORNER_RADIUS: int = 3


## Nombre de la variación de tema de tipo [param prefix] ([code]Panel[/code], [code]Button[/code] o
## [code]Bar[/code]) para el bando [param faction_id]: [code]PanelVardheim[/code]...
static func variation_name(prefix: String, faction_id: StringName) -> StringName:
	return StringName("%s%s" % [prefix, String(faction_id).capitalize()])


## Carga las fuentes del proyecto si ya están y devuelve el tema. Es lo que guarda
## [code]tools/ui/build_theme.gd[/code].
static func build_with_project_fonts() -> Theme:
	var body: Font = null
	var title: Font = null
	if ResourceLoader.exists(BODY_FONT_PATH):
		body = load(BODY_FONT_PATH) as Font
	if ResourceLoader.exists(TITLE_FONT_PATH):
		title = load(TITLE_FONT_PATH) as Font
	return build(body, title)


## Construye el tema. [param body_font] y [param title_font] son opcionales (null = la fuente del
## motor); ver la nota de fuentes en la documentación de la clase.
static func build(body_font: Font = null, title_font: Font = null) -> Theme:
	var theme: Theme = Theme.new()
	theme.default_font_size = FONT_SIZE
	if body_font != null:
		theme.default_font = body_font
	_build_labels(theme, title_font)
	_build_panels(theme)
	_build_buttons(theme)
	_build_toggles(theme)
	_build_bars(theme)
	_build_text_edits(theme)
	_build_sliders(theme)
	_build_tabs(theme, title_font)
	_build_lists_and_menus(theme)
	_build_scroll_and_separators(theme)
	_build_windows(theme, title_font)
	return theme


# --- Etiquetas --------------------------------------------------------------------------------

static func _build_labels(theme: Theme, title_font: Font) -> void:
	theme.set_color(&"font_color", &"Label", UIPalette.TEXT)
	theme.set_color(&"font_outline_color", &"Label", UIPalette.OUTLINE)
	theme.set_color(&"font_shadow_color", &"Label", Color(0.0, 0.0, 0.0, 0.0))
	theme.set_constant(&"outline_size", &"Label", 0)
	theme.set_constant(&"line_spacing", &"Label", 3)
	theme.set_font_size(&"font_size", &"Label", FONT_SIZE)

	_label_variation(theme, &"TitleLabel", TITLE_FONT_SIZE, UIPalette.TITLE, title_font)
	_label_variation(theme, &"HeaderLabel", HEADER_FONT_SIZE, UIPalette.TITLE, title_font)
	_label_variation(theme, &"DimLabel", SMALL_FONT_SIZE, UIPalette.TEXT_DIM, null)
	_label_variation(theme, &"WarningLabel", FONT_SIZE, UIPalette.WARNING, null)
	_label_variation(theme, &"ErrorLabel", FONT_SIZE, UIPalette.DANGER, null)
	_label_variation(theme, &"DebugLabel", FONT_SIZE, UIPalette.TEXT, null)
	# La línea de ayuda del HUD se lee sobre el mundo: blanca translúcida con contorno.
	_label_variation(theme, &"HintLabel", FONT_SIZE, UIPalette.with_alpha(Color.WHITE, 0.75), null)
	theme.set_color(&"font_outline_color", &"HintLabel", UIPalette.with_alpha(Color.BLACK, 0.6))
	theme.set_constant(&"outline_size", &"HintLabel", 4)

	theme.set_color(&"default_color", &"RichTextLabel", UIPalette.TEXT)
	theme.set_color(&"font_selected_color", &"RichTextLabel", UIPalette.TEXT)
	theme.set_color(&"selection_color", &"RichTextLabel", UIPalette.with_alpha(UIPalette.ACCENT, 0.35))
	theme.set_color(&"font_outline_color", &"RichTextLabel", UIPalette.OUTLINE)
	theme.set_font_size(&"normal_font_size", &"RichTextLabel", FONT_SIZE)
	theme.set_stylebox(&"normal", &"RichTextLabel", StyleBoxEmpty.new())
	theme.set_stylebox(&"focus", &"RichTextLabel", _focus_box(2))


static func _label_variation(theme: Theme, variation: StringName, size: int, color: Color,
		font: Font) -> void:
	theme.set_type_variation(variation, &"Label")
	theme.set_font_size(&"font_size", variation, size)
	theme.set_color(&"font_color", variation, color)
	if font != null:
		theme.set_font(&"font", variation, font)


# --- Paneles ----------------------------------------------------------------------------------

static func _build_panels(theme: Theme) -> void:
	var panel: StyleBoxFlat = _panel_box(UIPalette.PANEL_BG, UIPalette.BORDER)
	theme.set_stylebox(&"panel", &"Panel", panel)
	theme.set_stylebox(&"panel", &"PanelContainer", panel)

	theme.set_type_variation(&"InsetPanel", &"PanelContainer")
	theme.set_stylebox(&"panel", &"InsetPanel", _box(UIPalette.INSET_BG, UIPalette.BORDER_DIM, 1,
			CORNER_RADIUS, 8, 6))

	theme.set_type_variation(&"WindowPanel", &"PanelContainer")
	theme.set_stylebox(&"panel", &"WindowPanel", _panel_box(UIPalette.WINDOW_BG,
			UIPalette.BORDER_LIGHT, 14, 12))

	# El panel de depuración del HUD, tal y como era antes del tema.
	theme.set_type_variation(&"DebugPanel", &"PanelContainer")
	theme.set_stylebox(&"panel", &"DebugPanel", _box(UIPalette.DEBUG_BG, Color.TRANSPARENT, 0, 6,
			10, 8))

	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var variation: StringName = variation_name("Panel", faction_id)
		theme.set_type_variation(variation, &"PanelContainer")
		theme.set_stylebox(&"panel", variation, _panel_box(UIPalette.PANEL_BG,
				UIPalette.faction_border(faction_id)))

	# Tooltip del motor (los textos de ayuda de cualquier control).
	theme.set_stylebox(&"panel", &"TooltipPanel", _panel_box(UIPalette.WINDOW_BG,
			UIPalette.BORDER_LIGHT, 8, 6))
	theme.set_color(&"font_color", &"TooltipLabel", UIPalette.TEXT)
	theme.set_color(&"font_outline_color", &"TooltipLabel", UIPalette.OUTLINE)
	theme.set_constant(&"outline_size", &"TooltipLabel", 0)
	theme.set_font_size(&"font_size", &"TooltipLabel", SMALL_FONT_SIZE + 1)


# --- Botones ----------------------------------------------------------------------------------

static func _build_buttons(theme: Theme) -> void:
	_button_style(theme, &"Button", UIPalette.BORDER_DIM, UIPalette.BORDER_LIGHT, UIPalette.ACCENT,
			UIPalette.TEXT, UIPalette.ACCENT.lightened(0.4))
	theme.set_constant(&"h_separation", &"Button", 8)
	theme.set_constant(&"outline_size", &"Button", 0)
	theme.set_font_size(&"font_size", &"Button", FONT_SIZE)

	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var variation: StringName = variation_name("Button", faction_id)
		var accent: Color = UIPalette.accent_for(faction_id)
		theme.set_type_variation(variation, &"Button")
		_button_style(theme, variation, UIPalette.faction_border(faction_id), accent, accent,
				accent.lightened(0.3), accent.lightened(0.5))

	theme.set_type_variation(&"DangerButton", &"Button")
	_button_style(theme, &"DangerButton", UIPalette.DANGER.darkened(0.3), UIPalette.DANGER,
			UIPalette.DANGER, UIPalette.DANGER.lightened(0.35), UIPalette.DANGER.lightened(0.55))

	# Botón sin fondo ni borde (iconos, cerrar ventana): solo se ve al pasar el ratón o enfocarlo.
	theme.set_type_variation(&"GhostButton", &"Button")
	var ghost: StyleBoxFlat = _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, CORNER_RADIUS, 8, 4)
	theme.set_stylebox(&"normal", &"GhostButton", ghost)
	theme.set_stylebox(&"disabled", &"GhostButton", ghost)
	theme.set_stylebox(&"hover", &"GhostButton", _box(UIPalette.with_alpha(Color.WHITE, 0.08),
			Color.TRANSPARENT, 0, CORNER_RADIUS, 8, 4))
	theme.set_stylebox(&"pressed", &"GhostButton", _box(UIPalette.with_alpha(Color.WHITE, 0.14),
			Color.TRANSPARENT, 0, CORNER_RADIUS, 8, 4))
	theme.set_stylebox(&"focus", &"GhostButton", _focus_box(CORNER_RADIUS))


# Estilos y colores de un tipo de botón. [param border] es el borde en reposo, [param hover_border]
# el del ratón encima y [param press_border] el del botón pulsado; los dos últimos colores son los
# del texto en reposo y pulsado.
static func _button_style(theme: Theme, type: StringName, border: Color, hover_border: Color,
		press_border: Color, text: Color, pressed_text: Color) -> void:
	theme.set_stylebox(&"normal", type, _box(UIPalette.BUTTON_BG, border, 1, CORNER_RADIUS, 14, 7))
	theme.set_stylebox(&"hover", type, _box(UIPalette.BUTTON_BG_HOVER, hover_border, 1,
			CORNER_RADIUS, 14, 7))
	theme.set_stylebox(&"pressed", type, _box(UIPalette.BUTTON_BG_PRESSED, press_border, 1,
			CORNER_RADIUS, 14, 7))
	theme.set_stylebox(&"hover_pressed", type, _box(UIPalette.BUTTON_BG_PRESSED, hover_border, 1,
			CORNER_RADIUS, 14, 7))
	theme.set_stylebox(&"disabled", type, _box(UIPalette.BUTTON_BG_DISABLED,
			UIPalette.with_alpha(UIPalette.BORDER_DIM, 0.5), 1, CORNER_RADIUS, 14, 7))
	theme.set_stylebox(&"focus", type, _focus_box(CORNER_RADIUS))
	theme.set_color(&"font_color", type, text)
	theme.set_color(&"font_hover_color", type, text.lightened(0.2))
	theme.set_color(&"font_focus_color", type, text.lightened(0.1))
	theme.set_color(&"font_pressed_color", type, pressed_text)
	theme.set_color(&"font_hover_pressed_color", type, pressed_text)
	theme.set_color(&"font_disabled_color", type, UIPalette.TEXT_DISABLED)
	theme.set_color(&"icon_normal_color", type, text)
	theme.set_color(&"icon_hover_color", type, text.lightened(0.2))
	theme.set_color(&"icon_pressed_color", type, pressed_text)
	theme.set_color(&"icon_focus_color", type, text)
	theme.set_color(&"icon_disabled_color", type, UIPalette.TEXT_DISABLED)


# CheckBox y CheckButton heredan de Button: sin estilos propios en el tema tomarían la caja del
# botón. Se definen transparentes, con un velo al pasar el ratón.
static func _build_toggles(theme: Theme) -> void:
	for type: StringName in [&"CheckBox", &"CheckButton"]:
		var flat: StyleBoxFlat = _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, CORNER_RADIUS, 6, 4)
		for state: StringName in [&"normal", &"pressed", &"disabled"]:
			theme.set_stylebox(state, type, flat)
		var hover: StyleBoxFlat = _box(UIPalette.with_alpha(Color.WHITE, 0.07), Color.TRANSPARENT, 0,
				CORNER_RADIUS, 6, 4)
		theme.set_stylebox(&"hover", type, hover)
		theme.set_stylebox(&"hover_pressed", type, hover)
		theme.set_stylebox(&"focus", type, _focus_box(CORNER_RADIUS))
		theme.set_color(&"font_color", type, UIPalette.TEXT)
		theme.set_color(&"font_hover_color", type, UIPalette.TEXT.lightened(0.2))
		theme.set_color(&"font_focus_color", type, UIPalette.TEXT)
		theme.set_color(&"font_pressed_color", type, UIPalette.TEXT)
		theme.set_color(&"font_hover_pressed_color", type, UIPalette.TEXT.lightened(0.2))
		theme.set_color(&"font_disabled_color", type, UIPalette.TEXT_DISABLED)
		theme.set_constant(&"h_separation", type, 10)


# --- Barras -----------------------------------------------------------------------------------

static func _build_bars(theme: Theme) -> void:
	theme.set_stylebox(&"background", &"ProgressBar", _box(UIPalette.INSET_BG,
			UIPalette.BORDER_DIM, 1, 2, 0, 0))
	theme.set_stylebox(&"fill", &"ProgressBar", _box(UIPalette.ACCENT, Color.TRANSPARENT, 0, 2, 0, 0))
	theme.set_color(&"font_color", &"ProgressBar", UIPalette.TEXT)
	theme.set_color(&"font_outline_color", &"ProgressBar", UIPalette.OUTLINE)
	theme.set_constant(&"outline_size", &"ProgressBar", 3)
	theme.set_font_size(&"font_size", &"ProgressBar", SMALL_FONT_SIZE)

	_bar_variation(theme, &"HealthBar", UIPalette.HEALTH)
	_bar_variation(theme, &"StaminaBar", UIPalette.STAMINA)
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		_bar_variation(theme, variation_name("Bar", faction_id), UIPalette.accent_for(faction_id))


static func _bar_variation(theme: Theme, variation: StringName, fill: Color) -> void:
	theme.set_type_variation(variation, &"ProgressBar")
	theme.set_stylebox(&"fill", variation, _box(fill, Color.TRANSPARENT, 0, 2, 0, 0))


# --- Campos de texto --------------------------------------------------------------------------

static func _build_text_edits(theme: Theme) -> void:
	for type: StringName in [&"LineEdit", &"TextEdit"]:
		theme.set_stylebox(&"normal", type, _box(UIPalette.INSET_BG, UIPalette.BORDER_DIM, 1,
				CORNER_RADIUS, 8, 6))
		theme.set_stylebox(&"focus", type, _box(UIPalette.INSET_BG, UIPalette.ACCENT, 1,
				CORNER_RADIUS, 8, 6))
		theme.set_stylebox(&"read_only", type, _box(UIPalette.with_alpha(UIPalette.INSET_BG, 0.55),
				UIPalette.BORDER_DIM, 1, CORNER_RADIUS, 8, 6))
		theme.set_color(&"font_color", type, UIPalette.TEXT)
		theme.set_color(&"font_selected_color", type, UIPalette.TEXT)
		theme.set_color(&"font_placeholder_color", type, UIPalette.with_alpha(UIPalette.TEXT_DIM, 0.6))
		theme.set_color(&"caret_color", type, UIPalette.ACCENT.lightened(0.2))
		theme.set_color(&"selection_color", type, UIPalette.with_alpha(UIPalette.ACCENT, 0.35))
		theme.set_font_size(&"font_size", type, FONT_SIZE)
	theme.set_color(&"font_uneditable_color", &"LineEdit", UIPalette.TEXT_DIM)
	theme.set_constant(&"caret_width", &"LineEdit", 2)


# --- Deslizadores -----------------------------------------------------------------------------

static func _build_sliders(theme: Theme) -> void:
	var grabber: Texture2D = _dot_texture(UIPalette.TEXT, 18)
	var grabber_highlight: Texture2D = _dot_texture(UIPalette.ACCENT.lightened(0.35), 18)
	var grabber_disabled: Texture2D = _dot_texture(UIPalette.TEXT_DISABLED, 18)
	for type: StringName in [&"HSlider", &"VSlider"]:
		# El grosor de la pista lo dan los márgenes de la caja: arriba y abajo en el horizontal, a los
		# lados en el vertical.
		var track: StyleBoxFlat = _box(UIPalette.INSET_BG, UIPalette.BORDER_DIM, 1, 3, 0, 0)
		var fill: StyleBoxFlat = _box(UIPalette.with_alpha(UIPalette.ACCENT, 0.75),
				Color.TRANSPARENT, 0, 3, 0, 0)
		var fill_highlight: StyleBoxFlat = _box(UIPalette.ACCENT, Color.TRANSPARENT, 0, 3, 0, 0)
		for box: StyleBoxFlat in [track, fill, fill_highlight]:
			if type == &"HSlider":
				box.content_margin_top = 3.0
				box.content_margin_bottom = 3.0
			else:
				box.content_margin_left = 3.0
				box.content_margin_right = 3.0
		theme.set_stylebox(&"slider", type, track)
		theme.set_stylebox(&"grabber_area", type, fill)
		theme.set_stylebox(&"grabber_area_highlight", type, fill_highlight)
		theme.set_icon(&"grabber", type, grabber)
		theme.set_icon(&"grabber_highlight", type, grabber_highlight)
		theme.set_icon(&"grabber_disabled", type, grabber_disabled)


# Un círculo liso con borde suave, hecho con un degradado radial (ocupa casi nada en el .tres).
static func _dot_texture(color: Color, size: int) -> GradientTexture2D:
	var gradient: Gradient = Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.8, 1.0])
	gradient.colors = PackedColorArray([color, color, UIPalette.with_alpha(color, 0.0)])
	var texture: GradientTexture2D = GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = size
	texture.height = size
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


# --- Pestañas ---------------------------------------------------------------------------------

static func _build_tabs(theme: Theme, title_font: Font) -> void:
	var selected: StyleBoxFlat = _tab_box(UIPalette.PANEL_BG, UIPalette.BORDER_LIGHT)
	selected.border_width_top = 2
	var unselected: StyleBoxFlat = _tab_box(UIPalette.INSET_BG, UIPalette.BORDER_DIM)
	var hovered: StyleBoxFlat = _tab_box(UIPalette.BUTTON_BG_HOVER, UIPalette.BORDER)
	var disabled: StyleBoxFlat = _tab_box(UIPalette.with_alpha(UIPalette.INSET_BG, 0.5),
			UIPalette.BORDER_DIM)
	for type: StringName in [&"TabContainer", &"TabBar"]:
		theme.set_stylebox(&"tab_selected", type, selected)
		theme.set_stylebox(&"tab_unselected", type, unselected)
		theme.set_stylebox(&"tab_hovered", type, hovered)
		theme.set_stylebox(&"tab_disabled", type, disabled)
		theme.set_stylebox(&"tab_focus", type, _focus_box(CORNER_RADIUS))
		theme.set_color(&"font_selected_color", type, UIPalette.TITLE)
		theme.set_color(&"font_unselected_color", type, UIPalette.TEXT_DIM)
		theme.set_color(&"font_hovered_color", type, UIPalette.TEXT)
		theme.set_color(&"font_disabled_color", type, UIPalette.TEXT_DISABLED)
		theme.set_color(&"font_outline_color", type, UIPalette.OUTLINE)
		theme.set_constant(&"outline_size", type, 0)
		theme.set_constant(&"h_separation", type, 4)
		theme.set_font_size(&"font_size", type, FONT_SIZE)
		if title_font != null:
			theme.set_font(&"font", type, title_font)
	var content: StyleBoxFlat = _panel_box(UIPalette.PANEL_BG, UIPalette.BORDER)
	content.corner_radius_top_left = 0
	theme.set_stylebox(&"panel", &"TabContainer", content)
	theme.set_stylebox(&"tabbar_background", &"TabContainer", StyleBoxEmpty.new())


static func _tab_box(bg: Color, border: Color) -> StyleBoxFlat:
	var box: StyleBoxFlat = _box(bg, border, 1, CORNER_RADIUS, 14, 6)
	box.corner_radius_bottom_left = 0
	box.corner_radius_bottom_right = 0
	return box


# --- Listas y menús ---------------------------------------------------------------------------

static func _build_lists_and_menus(theme: Theme) -> void:
	theme.set_stylebox(&"panel", &"ItemList", _box(UIPalette.INSET_BG, UIPalette.BORDER_DIM, 1,
			CORNER_RADIUS, 4, 4))
	theme.set_stylebox(&"focus", &"ItemList", _focus_box(CORNER_RADIUS))
	var selected: StyleBoxFlat = _box(UIPalette.with_alpha(UIPalette.ACCENT, 0.28),
			UIPalette.with_alpha(UIPalette.ACCENT, 0.7), 1, 2, 4, 2)
	theme.set_stylebox(&"selected", &"ItemList", selected)
	theme.set_stylebox(&"selected_focus", &"ItemList", selected)
	theme.set_stylebox(&"hovered", &"ItemList", _box(UIPalette.with_alpha(Color.WHITE, 0.07),
			Color.TRANSPARENT, 0, 2, 4, 2))
	theme.set_stylebox(&"cursor", &"ItemList", _focus_box(2))
	theme.set_stylebox(&"cursor_unfocused", &"ItemList", StyleBoxEmpty.new())
	theme.set_color(&"font_color", &"ItemList", UIPalette.TEXT_DIM)
	theme.set_color(&"font_hovered_color", &"ItemList", UIPalette.TEXT)
	theme.set_color(&"font_selected_color", &"ItemList", UIPalette.TEXT)
	theme.set_color(&"guide_color", &"ItemList", UIPalette.BORDER_DIM)
	theme.set_constant(&"v_separation", &"ItemList", 4)
	theme.set_font_size(&"font_size", &"ItemList", FONT_SIZE)

	var menu_panel: StyleBoxFlat = _box(UIPalette.WINDOW_BG, UIPalette.BORDER_LIGHT, 1,
			CORNER_RADIUS, 4, 4)
	theme.set_stylebox(&"panel", &"PopupMenu", menu_panel)
	theme.set_stylebox(&"panel", &"PopupPanel", menu_panel)
	theme.set_stylebox(&"hover", &"PopupMenu", _box(UIPalette.with_alpha(UIPalette.ACCENT, 0.3),
			Color.TRANSPARENT, 0, 2, 6, 3))
	theme.set_color(&"font_color", &"PopupMenu", UIPalette.TEXT)
	theme.set_color(&"font_hover_color", &"PopupMenu", UIPalette.TEXT)
	theme.set_color(&"font_disabled_color", &"PopupMenu", UIPalette.TEXT_DISABLED)
	theme.set_color(&"font_accelerator_color", &"PopupMenu", UIPalette.TEXT_DIM)
	theme.set_color(&"font_separator_color", &"PopupMenu", UIPalette.TEXT_DIM)
	theme.set_constant(&"v_separation", &"PopupMenu", 6)
	theme.set_constant(&"h_separation", &"PopupMenu", 8)
	theme.set_font_size(&"font_size", &"PopupMenu", FONT_SIZE)


# --- Barras de desplazamiento y separadores ---------------------------------------------------

static func _build_scroll_and_separators(theme: Theme) -> void:
	for type: StringName in [&"HScrollBar", &"VScrollBar"]:
		var scroll: StyleBoxFlat = _box(UIPalette.with_alpha(UIPalette.INSET_BG, 0.6),
				Color.TRANSPARENT, 0, 3, 0, 0)
		scroll.content_margin_left = 4.0
		scroll.content_margin_right = 4.0
		scroll.content_margin_top = 4.0
		scroll.content_margin_bottom = 4.0
		theme.set_stylebox(&"scroll", type, scroll)
		theme.set_stylebox(&"scroll_focus", type, scroll)
		theme.set_stylebox(&"grabber", type, _scroll_grabber(UIPalette.BORDER))
		theme.set_stylebox(&"grabber_highlight", type, _scroll_grabber(UIPalette.BORDER_LIGHT))
		theme.set_stylebox(&"grabber_pressed", type, _scroll_grabber(UIPalette.ACCENT))
	for type: StringName in [&"HSeparator", &"VSeparator"]:
		var line: StyleBoxLine = StyleBoxLine.new()
		line.color = UIPalette.BORDER_DIM
		line.thickness = 1
		line.vertical = type == &"VSeparator"
		theme.set_stylebox(&"separator", type, line)
		theme.set_constant(&"separation", type, 10)


static func _scroll_grabber(color: Color) -> StyleBoxFlat:
	var box: StyleBoxFlat = _box(color, Color.TRANSPARENT, 0, 3, 0, 0)
	box.content_margin_left = 4.0
	box.content_margin_right = 4.0
	box.content_margin_top = 4.0
	box.content_margin_bottom = 4.0
	return box


# --- Ventanas ---------------------------------------------------------------------------------

static func _build_windows(theme: Theme, title_font: Font) -> void:
	# Marco de las ventanas incrustadas del motor (AcceptDialog, ConfirmationDialog...): el borde
	# se dibuja alrededor del contenido y la barra del título cae en el margen superior.
	for style_name: StringName in [&"embedded_border", &"embedded_unfocused_border"]:
		var frame: StyleBoxFlat = _box(UIPalette.WINDOW_BG,
				UIPalette.BORDER_LIGHT if style_name == &"embedded_border" else UIPalette.BORDER,
				1, CORNER_RADIUS, 10, 6)
		frame.border_width_top = 2
		frame.content_margin_top = float(WINDOW_TITLE_HEIGHT + 4)
		frame.expand_margin_top = float(WINDOW_TITLE_HEIGHT + 4)
		frame.expand_margin_left = 10.0
		frame.expand_margin_right = 10.0
		frame.expand_margin_bottom = 8.0
		theme.set_stylebox(style_name, &"Window", frame)
	theme.set_color(&"title_color", &"Window", UIPalette.TITLE)
	theme.set_color(&"title_outline_modulate", &"Window", Color(0.0, 0.0, 0.0, 0.0))
	theme.set_constant(&"title_height", &"Window", WINDOW_TITLE_HEIGHT)
	theme.set_constant(&"title_outline_size", &"Window", 0)
	theme.set_constant(&"resize_margin", &"Window", 4)
	theme.set_font_size(&"title_font_size", &"Window", HEADER_FONT_SIZE - 2)
	if title_font != null:
		theme.set_font(&"title_font", &"Window", title_font)
	# El fondo del contenido de un diálogo.
	theme.set_stylebox(&"panel", &"AcceptDialog", _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 0,
			8, 6))


# --- Fábricas de estilos ----------------------------------------------------------------------

# Caja plana con fondo [param bg], borde [param border] de [param border_width] píxeles, esquinas
# redondeadas y márgenes de contenido. Con antialiasing para que las esquinas no se vean escalonadas.
static func _box(bg: Color, border: Color, border_width: int, radius: int, margin_x: int,
		margin_y: int) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = float(margin_x)
	box.content_margin_right = float(margin_x)
	box.content_margin_top = float(margin_y)
	box.content_margin_bottom = float(margin_y)
	box.anti_aliasing = true
	return box


# Panel con el remate: el borde superior es más grueso que los demás, y una sombra suave.
static func _panel_box(bg: Color, border: Color, margin_x: int = 10, margin_y: int = 8) -> StyleBoxFlat:
	var box: StyleBoxFlat = _box(bg, border, 1, CORNER_RADIUS, margin_x, margin_y)
	box.border_width_top = 2
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.3)
	box.shadow_size = 4
	return box


# Contorno de foco: sin relleno y con un borde de acento, para navegar con teclado o mando.
static func _focus_box(radius: int) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.draw_center = false
	box.border_color = UIPalette.ACCENT.lightened(0.15)
	box.set_border_width_all(2)
	box.set_corner_radius_all(radius)
	box.anti_aliasing = true
	return box
