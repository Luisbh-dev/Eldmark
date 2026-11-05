extends TestCase
## Tests for the visual theme (UI-02): the global Theme ([UIThemeBuilder] and its
## [code]eldmark_theme.tres[/code] file), the palette ([UIPalette]), the side emblems, that the HUD uses
## the theme without loose overrides and that the gallery ([UIGallery]) shows all the styles.

const THEME_PATH: String = "res://assets/ui/theme/eldmark_theme.tres"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const GALLERY_SCENE_PATH: String = "res://scenes/tests/ui_gallery.tscn"
## Interface scenes that must no longer carry system fonts, loose style boxes or
## overrides: the theme provides them.
const THEMED_SCENES: Array[String] = [
	"res://scenes/ui/hud.tscn", "res://scenes/ui/net_debug_overlay.tscn",
]

var _nodes: Array[Node] = []


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()


func _add(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


# --- The theme --------------------------------------------------------------------------------

func test_the_project_uses_the_theme_file() -> void:
	assert_eq(String(ProjectSettings.get_setting("gui/theme/custom", "")), THEME_PATH,
			"project.godot assigns the theme")
	assert_eq(UIThemeBuilder.THEME_PATH, THEME_PATH)
	var theme: Theme = load(THEME_PATH) as Theme
	assert_not_null(theme, "the file is a Theme")
	assert_true(FileAccess.get_file_as_string(THEME_PATH).begins_with("[gd_resource type=\"Theme\""),
			"and it is in text format")
	assert_not_null(ThemeDB.get_project_theme(), "the project has it loaded")
	var label: Label = _add(Label.new()) as Label
	assert_eq(label.get_theme_color(&"font_color"), UIPalette.TEXT,
			"any Label sees the theme's colors")


func test_the_theme_file_matches_the_builder() -> void:
	var saved: Theme = load(THEME_PATH) as Theme
	if not assert_not_null(saved):
		return
	var built: Theme = UIThemeBuilder.build_with_project_fonts()
	var differences: PackedStringArray = _theme_differences(saved, built)
	assert_eq(differences, PackedStringArray(),
			"the file is out of date: rerun tools/ui/build_theme.gd")
	# The comparison does not pass vacuously: a different theme is detected.
	var changed: Theme = UIThemeBuilder.build_with_project_fonts()
	changed.set_color(&"font_color", &"Label", Color.RED)
	assert_false(_theme_differences(saved, changed).is_empty(), "detects a different color")


func test_the_theme_styles_every_required_type() -> void:
	var theme: Theme = load(THEME_PATH) as Theme
	for state: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		assert_true(theme.has_stylebox(state, &"Button"), "Button.%s" % state)
	assert_true(theme.has_stylebox(&"panel", &"Panel"))
	assert_true(theme.has_stylebox(&"panel", &"PanelContainer"))
	assert_true(theme.has_color(&"font_color", &"Label"))
	assert_true(theme.has_stylebox(&"background", &"ProgressBar"))
	assert_true(theme.has_stylebox(&"fill", &"ProgressBar"))
	assert_true(theme.has_stylebox(&"normal", &"LineEdit"))
	assert_true(theme.has_stylebox(&"focus", &"LineEdit"))
	assert_true(theme.has_stylebox(&"embedded_border", &"Window"), "window")
	assert_true(theme.has_stylebox(&"tab_selected", &"TabContainer"))
	assert_true(theme.has_stylebox(&"slider", &"HSlider"))
	assert_true(theme.has_icon(&"grabber", &"HSlider"))
	assert_true(theme.has_stylebox(&"panel", &"TooltipPanel"))
	assert_eq(theme.default_font_size, UIThemeBuilder.FONT_SIZE)
	for styled: String in ["Panel", "PanelContainer", "Button", "Label", "ProgressBar", "LineEdit",
			"Window"]:
		assert_true(theme.get_type_list().has(styled), "the theme has the type %s" % styled)


func test_controls_pick_the_theme_styles_up() -> void:
	var button: Button = _add(Button.new()) as Button
	var normal: StyleBoxFlat = button.get_theme_stylebox(&"normal") as StyleBoxFlat
	assert_not_null(normal, "the button uses a StyleBoxFlat")
	assert_eq(normal.bg_color, UIPalette.BUTTON_BG)
	var focus: StyleBoxFlat = button.get_theme_stylebox(&"focus") as StyleBoxFlat
	assert_false(focus.draw_center, "focus is just an outline")
	assert_eq(button.get_theme_font_size(&"font_size"), UIThemeBuilder.FONT_SIZE)
	var panel: PanelContainer = _add(PanelContainer.new()) as PanelContainer
	var panel_box: StyleBoxFlat = panel.get_theme_stylebox(&"panel") as StyleBoxFlat
	assert_eq(panel_box.bg_color, UIPalette.PANEL_BG)
	assert_true(panel_box.border_width_top > panel_box.border_width_bottom,
			"the thicker top border is the trim")
	assert_true(panel_box.bg_color.a < 1.0, "translucent")
	var edit: LineEdit = _add(LineEdit.new()) as LineEdit
	assert_eq((edit.get_theme_stylebox(&"focus") as StyleBoxFlat).border_color, UIPalette.ACCENT)
	var bar: ProgressBar = _add(ProgressBar.new()) as ProgressBar
	assert_eq((bar.get_theme_stylebox(&"fill") as StyleBoxFlat).bg_color, UIPalette.ACCENT)


func test_check_boxes_do_not_inherit_the_button_box() -> void:
	# CheckBox and CheckButton inherit from Button: without their own styles they would take the button's box.
	var theme: Theme = load(THEME_PATH) as Theme
	for type: StringName in [&"CheckBox", &"CheckButton"]:
		var normal: StyleBoxFlat = theme.get_stylebox(&"normal", type) as StyleBoxFlat
		assert_not_null(normal, "%s has its own normal style" % type)
		assert_eq(normal.bg_color.a, 0.0, "%s is transparent at rest" % type)
		assert_eq(normal.border_width_left, 0)


func test_label_variations() -> void:
	var theme: Theme = load(THEME_PATH) as Theme
	for variation: StringName in [&"TitleLabel", &"HeaderLabel", &"DimLabel", &"WarningLabel",
			&"ErrorLabel", &"HintLabel", &"DebugLabel"]:
		assert_eq(theme.get_type_variation_base(variation), &"Label", "%s derives from Label"
				% variation)
	var title: Label = _add(Label.new()) as Label
	title.theme_type_variation = &"TitleLabel"
	assert_eq(title.get_theme_font_size(&"font_size"), UIThemeBuilder.TITLE_FONT_SIZE)
	assert_eq(title.get_theme_color(&"font_color"), UIPalette.TITLE)
	var hint: Label = _add(Label.new()) as Label
	hint.theme_type_variation = &"HintLabel"
	assert_eq(hint.get_theme_constant(&"outline_size"), 4, "the help has an outline")
	assert_eq(hint.get_theme_color(&"font_color").a, 0.75)
	var plain: Label = _add(Label.new()) as Label
	assert_eq(plain.get_theme_constant(&"outline_size"), 0, "a normal label does not")


func test_every_faction_has_accented_variations() -> void:
	var theme: Theme = load(THEME_PATH) as Theme
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var color: Color = RealmCatalog.color_of(faction_id)
		var panel_name: StringName = UIThemeBuilder.variation_name("Panel", faction_id)
		var button_name: StringName = UIThemeBuilder.variation_name("Button", faction_id)
		var bar_name: StringName = UIThemeBuilder.variation_name("Bar", faction_id)
		assert_eq(theme.get_type_variation_base(panel_name), &"PanelContainer")
		assert_eq(theme.get_type_variation_base(button_name), &"Button")
		assert_eq(theme.get_type_variation_base(bar_name), &"ProgressBar")
		var panel_box: StyleBoxFlat = theme.get_stylebox(&"panel", panel_name) as StyleBoxFlat
		assert_eq(panel_box.border_color, UIPalette.faction_border(faction_id),
				"%s: the panel's border is the side's" % faction_id)
		var hover: StyleBoxFlat = theme.get_stylebox(&"hover", button_name) as StyleBoxFlat
		assert_eq(hover.border_color, color, "%s: the button lights up with its color" % faction_id)
		var fill: StyleBoxFlat = theme.get_stylebox(&"fill", bar_name) as StyleBoxFlat
		assert_eq(fill.bg_color, color, "%s: the bar fills with its color" % faction_id)
	assert_eq(UIThemeBuilder.variation_name("Panel", &"vardheim"), &"PanelVardheim")
	assert_eq(UIThemeBuilder.variation_name("Bar", &"huecos"), &"BarHuecos")


func test_font_slots_are_ready_and_nothing_uses_a_system_font() -> void:
	var plain: Theme = UIThemeBuilder.build()
	assert_null(plain.default_font, "without chosen fonts the engine's is used")
	assert_false(plain.has_font(&"font", &"TitleLabel"), "and the title slot is free")
	var body: FontVariation = FontVariation.new()
	var title: FontVariation = FontVariation.new()
	var themed: Theme = UIThemeBuilder.build(body, title)
	assert_eq(themed.default_font, body, "the body font is the default one")
	assert_eq(themed.get_font(&"font", &"TitleLabel"), title, "the title font goes to the titles")
	assert_eq(themed.get_font(&"font", &"HeaderLabel"), title)
	assert_eq(themed.get_font(&"title_font", &"Window"), title, "and to the windows' title")
	assert_false(FileAccess.get_file_as_string(THEME_PATH).contains("SystemFont"),
			"the theme file does not use system fonts")
	assert_eq(UIThemeBuilder.BODY_FONT_PATH.get_base_dir(), "res://assets/fonts")
	assert_eq(UIThemeBuilder.TITLE_FONT_PATH.get_base_dir(), "res://assets/fonts")


func test_the_licence_file_notes_the_missing_fonts_and_the_placeholder_emblems() -> void:
	var text: String = FileAccess.get_file_as_string("res://assets/LICENSES.md")
	assert_true(text.contains("Noto Sans"), "records the body font")
	assert_true(text.contains("Cinzel"), "and the titles'")
	assert_true(text.contains("assets/emblems"), "and the placeholder emblems")
	assert_true(text.contains("provisional"))


# --- The palette ------------------------------------------------------------------------------

func test_palette_faction_colors_come_from_the_realm_catalog() -> void:
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		assert_eq(UIPalette.faction_color(faction_id), RealmCatalog.color_of(faction_id))
		assert_eq(UIPalette.accent_for(faction_id), RealmCatalog.color_of(faction_id))
		assert_eq(UIPalette.faction_color_of_code(RealmCatalog.code_of(faction_id)),
				RealmCatalog.color_of(faction_id))
	assert_eq(UIPalette.accent_for(&"nadie"), UIPalette.ACCENT, "with no side, the neutral accent")
	assert_eq(UIPalette.accent_for(&""), UIPalette.ACCENT)
	var border: Color = UIPalette.faction_border(&"solmarch")
	assert_true(border.r < RealmCatalog.SOLMARCH_COLOR.r, "the border is the darkened color")
	assert_eq(UIPalette.emblem_path(&"vardheim"), "res://assets/emblems/vardheim.svg")


func test_rarity_colors_and_names() -> void:
	assert_eq(UIPalette.RARITY_COLORS.size(), 5)
	assert_eq(UIPalette.RARITY_NAMES.size(), 5)
	for rarity: int in 5:
		assert_eq(UIPalette.rarity_color(rarity), UIPalette.RARITY_COLORS[rarity])
		for other: int in rarity:
			assert_ne_color(UIPalette.rarity_color(rarity), UIPalette.rarity_color(other))
	assert_eq(UIPalette.rarity_color(UIPalette.Rarity.COMMON), UIPalette.RARITY_COLORS[0])
	assert_eq(UIPalette.rarity_color(99), UIPalette.rarity_color(0), "out of range, common")
	assert_eq(UIPalette.rarity_color(-1), UIPalette.rarity_color(0))
	assert_eq(UIPalette.rarity_name(UIPalette.Rarity.EPIC), "Épico")
	assert_eq(UIPalette.rarity_name(42), "Común")


func test_text_color_is_readable_on_light_and_dark() -> void:
	assert_eq(UIPalette.text_on(UIPalette.PANEL_BG), UIPalette.TEXT)
	assert_ne_color(UIPalette.text_on(RealmCatalog.SOLMARCH_COLOR), UIPalette.TEXT)
	assert_true(UIPalette.luminance(Color.WHITE) > UIPalette.luminance(Color.BLACK))
	assert_eq(UIPalette.with_alpha(Color.RED, 0.5), Color(1.0, 0.0, 0.0, 0.5))


func assert_ne_color(a: Color, b: Color) -> void:
	assert_false(a.is_equal_approx(b), "%s and %s should be different" % [a, b])


# --- Emblems ----------------------------------------------------------------------------------

func test_every_faction_has_a_provisional_emblem_in_its_colors() -> void:
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var path: String = RealmCatalog.emblem_path(faction_id)
		assert_eq(path, "res://assets/emblems/%s.svg" % faction_id, "path that RealmCatalog expects")
		assert_true(FileAccess.file_exists(path), "%s exists" % path)
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.contains("<svg"), "%s is an SVG" % path)
		assert_true(text.to_upper().contains(RealmCatalog.color_of(faction_id).to_html(false).to_upper()),
				"%s carries the side's color" % path)
		assert_true(text.contains("provisional"), "%s is marked as placeholder" % path)
		var texture: Texture2D = UIPalette.load_emblem(faction_id)
		assert_not_null(texture, "%s is imported as a texture" % path)
		if texture != null:
			assert_eq(texture.get_size(), Vector2(128.0, 128.0))
	assert_null(UIPalette.load_emblem(&"nadie"), "a side that does not exist has no emblem")


# --- The HUD without overrides ----------------------------------------------------------------

func test_themed_scenes_have_no_loose_fonts_styles_or_overrides() -> void:
	for path: String in THEMED_SCENES:
		var text: String = FileAccess.get_file_as_string(path)
		assert_false(text.is_empty(), "%s is read" % path)
		assert_false(text.contains("SystemFont"), "%s does not use system fonts" % path)
		assert_false(text.contains("theme_override_"), "%s has no theme overrides" % path)
		assert_false(text.contains("StyleBoxFlat"), "%s has no loose style boxes" % path)
		assert_false(text.contains("[sub_resource"), "%s has no subresources" % path)
		assert_true(text.contains("theme_type_variation"), "%s uses theme variations" % path)


func test_the_hud_gets_its_look_from_the_theme() -> void:
	var hud: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_add(hud)
	var panel: PanelContainer = hud.get_node(^"DebugPanel") as PanelContainer
	var box: StyleBoxFlat = panel.get_theme_stylebox(&"panel") as StyleBoxFlat
	assert_eq(box.bg_color, UIPalette.DEBUG_BG, "the debug panel comes from the theme")
	var label: Label = hud.get_node(^"DebugPanel/DebugLabel") as Label
	assert_eq(label.get_theme_font_size(&"font_size"), UIThemeBuilder.FONT_SIZE)
	assert_eq(label.get_theme_color(&"font_color"), UIPalette.TEXT)
	var bar: UIHintBar = hud.get_node(^"HintLabel") as UIHintBar
	var hint: Label = bar.find_children("*", "Label", true, false)[0] as Label
	assert_eq(hint.theme_type_variation, &"HintLabel", "the help uses the theme variation")
	assert_eq(hint.get_theme_constant(&"outline_size"), 4)
	assert_eq(hint.get_theme_color(&"font_outline_color"), UIPalette.with_alpha(Color.BLACK, 0.6))


# --- The gallery ------------------------------------------------------------------------------

func test_the_gallery_shows_every_style_of_the_theme() -> void:
	var gallery: UIGallery = (load(GALLERY_SCENE_PATH) as PackedScene).instantiate() as UIGallery
	if not assert_not_null(gallery, "the gallery scene loads"):
		return
	_add(gallery)
	await wait_process_frames(2)
	var theme: Theme = load(THEME_PATH) as Theme
	var shown: int = 0
	for type: StringName in theme.get_type_list():
		assert_true(gallery.shows_theme_type(type), "the gallery shows the type %s" % type)
		shown += 1
	assert_true(shown >= 30, "all the theme's types have been checked (%d)" % shown)
	# And the check does not pass vacuously.
	assert_false(gallery.shows_theme_type(&"TipoQueNoExiste"))
	for faction_id: StringName in RealmCatalog.FACTION_IDS:
		var emblem: TextureRect = gallery.find_child("Bando%s" % String(faction_id).capitalize(),
				true, false).get_node(^"Emblema") as TextureRect
		assert_not_null(emblem.texture, "the gallery shows %s's emblem" % faction_id)


func test_the_gallery_dialog_opens_and_closes() -> void:
	var gallery: UIGallery = (load(GALLERY_SCENE_PATH) as PackedScene).instantiate() as UIGallery
	_add(gallery)
	await wait_process_frames(2)
	var dialog: AcceptDialog = gallery.get_dialog()
	assert_not_null(dialog)
	assert_false(dialog.visible)
	dialog.popup_centered()
	await wait_process_frames(2)
	assert_true(dialog.visible, "it opens")
	dialog.hide()
	await wait_process_frames(1)
	assert_false(dialog.visible, "it closes")


# --- Utilities --------------------------------------------------------------------------------

# Differences between two themes (empty = equal): types, and for each one colors, constants, font
# sizes, style boxes (property by property), icons (class and size) and base variation.
func _theme_differences(a: Theme, b: Theme) -> PackedStringArray:
	var diffs: PackedStringArray = PackedStringArray()
	var types_a: PackedStringArray = a.get_type_list()
	var types_b: PackedStringArray = b.get_type_list()
	types_a.sort()
	types_b.sort()
	if types_a != types_b:
		diffs.append("tipos distintos")
		return diffs
	if a.default_font_size != b.default_font_size:
		diffs.append("tamaño de fuente por defecto")
	if (a.default_font == null) != (b.default_font == null):
		diffs.append("fuente por defecto")
	for type: String in types_a:
		if a.get_type_variation_base(type) != b.get_type_variation_base(type):
			diffs.append("%s: variación base" % type)
		for name: String in a.get_color_list(type):
			if not b.has_color(name, type) or not a.get_color(name, type).is_equal_approx(
					b.get_color(name, type)):
				diffs.append("%s.%s (color)" % [type, name])
		for name: String in a.get_constant_list(type):
			if not b.has_constant(name, type) or a.get_constant(name, type) != b.get_constant(name, type):
				diffs.append("%s.%s (constante)" % [type, name])
		for name: String in a.get_font_size_list(type):
			if not b.has_font_size(name, type) or a.get_font_size(name, type) != b.get_font_size(name, type):
				diffs.append("%s.%s (tamaño de fuente)" % [type, name])
		for name: String in a.get_font_list(type):
			if not b.has_font(name, type):
				diffs.append("%s.%s (fuente)" % [type, name])
		for name: String in a.get_icon_list(type):
			if not b.has_icon(name, type) or a.get_icon(name, type).get_class() \
					!= b.get_icon(name, type).get_class() \
					or a.get_icon(name, type).get_size() != b.get_icon(name, type).get_size():
				diffs.append("%s.%s (icono)" % [type, name])
		for name: String in a.get_stylebox_list(type):
			if not b.has_stylebox(name, type) or not _boxes_equal(a.get_stylebox(name, type),
					b.get_stylebox(name, type)):
				diffs.append("%s.%s (caja de estilo)" % [type, name])
	return diffs


func _boxes_equal(a: StyleBox, b: StyleBox) -> bool:
	if a.get_class() != b.get_class():
		return false
	for property: Dictionary in a.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var name: String = property["name"]
		if name == "resource_path" or name == "resource_name" or name == "script":
			continue
		var value_a: Variant = a.get(name)
		var value_b: Variant = b.get(name)
		if typeof(value_a) == TYPE_COLOR:
			if not (value_a as Color).is_equal_approx(value_b as Color):
				return false
		elif typeof(value_a) == TYPE_FLOAT:
			if not is_equal_approx(value_a as float, value_b as float):
				return false
		elif value_a != value_b:
			return false
	return true
