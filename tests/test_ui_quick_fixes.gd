extends TestCase
## Pruebas de los arreglos baratos de interfaz de la primera prueba con ventana (docs/calidad.md, oleada 1; UI-49,
## UI-50, UI-52 y UI-54): brújula, panel del fuerte y aviso de derribado centrados en la pantalla, tooltips que no se
## abren por foco al abrir una ventana, figura de personaje en reposo, línea de ayuda oculta, viñeta de daño
## proporcional, terreno del minimapa con fundido a niebla y filtro de marcadores del mundo.

const SCREEN: Vector2 = Vector2(1920.0, 1080.0)
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const SETTINGS_PATH: String = "user://test_ui_quick_fixes.cfg"
const ZONE_ID: StringName = &"vado_gris"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH

var _nodes: Array[Node] = []
var _saved_settings: ClientSettings = null


func before_each() -> void:
	_saved_settings = ClientSettings.current()
	ClientSettings.set_current(ClientSettings.load_from(SETTINGS_PATH))


func after_each() -> void:
	ClientSettings.set_current(_saved_settings)
	if FileAccess.file_exists(SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _add(node: Node, parent: Node = null) -> Node:
	(parent if parent != null else tree.root).add_child(node)
	_nodes.append(node)
	return node


## Un control del tamaño de la pantalla de 1920 x 1080 donde colgar el elemento del HUD que se prueba.
func _screen_parent() -> Control:
	var screen := Control.new()
	screen.name = "PantallaDePrueba"
	screen.size = SCREEN
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(screen)
	screen.size = SCREEN
	return screen


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	return event


# --- UI-49: centrado ---------------------------------------------------------------------------

func test_the_compass_is_centered_on_the_screen() -> void:
	var screen: Control = _screen_parent()
	var compass: Compass = _add(Compass.new(), screen) as Compass
	await wait_process_frames(2)
	var rect: Rect2 = compass.get_global_rect()
	assert_near(rect.get_center().x, SCREEN.x * 0.5, 1.0, "centro en x = 960 ± 1 (estaba con el borde izquierdo en 960)")
	assert_near(rect.size.x, Compass.WIDTH, 0.5)
	assert_near(rect.position.y, Compass.TOP_MARGIN, 0.5)
	screen.size = Vector2(1280.0, 720.0)
	await wait_process_frames(2)
	assert_near(compass.get_global_rect().get_center().x, 640.0, 1.0, "y sigue al centro si la pantalla cambia")


func test_the_capture_panel_is_centered_on_the_screen() -> void:
	var screen: Control = _screen_parent()
	var panel: CapturePanel = _add(CapturePanel.new(), screen) as CapturePanel
	panel.visible = true
	await wait_process_frames(2)
	var rect: Rect2 = panel.get_global_rect()
	assert_near(rect.get_center().x, SCREEN.x * 0.5, 1.0, "centro en x = 960 ± 1")
	assert_near(rect.size.x, CapturePanel.PANEL_WIDTH, 0.5)
	assert_near(rect.position.y, CapturePanel.TOP_MARGIN, 0.5)
	assert_true(rect.size.y > 20.0, "y con la altura de su contenido")


func test_the_downed_notice_is_centered_and_not_cut_off() -> void:
	var screen: Control = _screen_parent()
	var notice: DownedNotice = _add(DownedNotice.new(), screen) as DownedNotice
	notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	notice.update_view(true, 100, 0)
	await wait_process_frames(2)
	var column: Control = notice.get_node(^"Columna") as Control
	var rect: Rect2 = column.get_global_rect()
	assert_near(rect.get_center().x, SCREEN.x * 0.5, 1.0, "la columna está centrada en la pantalla")
	assert_true(rect.position.x >= 0.0, "y entera, sin salirse por la izquierda (%s)" % rect)
	assert_true(rect.end.x <= SCREEN.x)
	assert_near(rect.position.y, DownedNotice.TOP_OFFSET, 0.5)
	var title: Label = notice.get_node(^"Columna/Titulo") as Label
	assert_true(title.get_global_rect().position.x >= 0.0, "el título de derribado se ve entero")


func test_the_top_center_helper_keeps_the_width_and_grows_both_ways() -> void:
	var screen: Control = _screen_parent()
	var control := Control.new()
	control.custom_minimum_size = Vector2(300.0, 40.0)
	_add(control, screen)
	UILayout.anchor_top_center(control, 300.0, 12.0)
	await wait_process_frames(2)
	assert_near(control.get_global_rect().get_center().x, 960.0, 0.5)
	assert_near(control.size.x, 300.0, 0.5)
	assert_near(control.position.y, 12.0, 0.5)
	control.custom_minimum_size = Vector2(400.0, 40.0)
	await wait_process_frames(2)
	assert_near(control.get_global_rect().get_center().x, 960.0, 0.5, "si crece, lo hace por los dos lados")


# --- UI-49: tooltip por foco --------------------------------------------------------------------

func test_focus_opens_no_tooltip_unless_it_comes_from_the_keyboard_and_not_from_code() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = Rect2(Vector2.ZERO, SCREEN)
	var row := HBoxContainer.new()
	_add(row)
	var first := Button.new()
	var second := Button.new()
	for button: Button in [first, second]:
		button.focus_mode = Control.FOCUS_ALL
		row.add_child(button)
		tooltip.bind_source(button, func() -> Dictionary: return {"title": "Objeto", "body": "Texto"})
	assert_false(tooltip.allows_focus_tooltip(), "sin haber pulsado nada, no")
	# Abrir una ventana con una tecla (la I del inventario) enfoca su primer control sin tooltip.
	tooltip.note_input(_key(KEY_I))
	assert_true(tooltip.allows_focus_tooltip(), "con el teclado, el foco puede enseñar tooltips")
	var focused: Control = UIFocus.focus_first(row)
	assert_eq(focused, first)
	assert_true(first.has_focus())
	assert_false(tooltip.is_pending() or tooltip.is_showing(), "pero el foco que da el código al abrir la ventana no abre nada")
	# Navegar con las flechas sí.
	second.grab_focus()
	assert_true(tooltip.is_pending(), "el foco por navegación con el teclado abre el tooltip")
	tooltip.cancel()
	# Con el ratón, no.
	tooltip.note_input(InputEventMouseMotion.new())
	assert_false(tooltip.allows_focus_tooltip())
	first.grab_focus()
	assert_false(tooltip.is_pending(), "con el ratón, el foco no abre tooltips")
	# El mando también cuenta.
	var pad := InputEventJoypadButton.new()
	pad.pressed = true
	tooltip.note_input(pad)
	assert_true(tooltip.allows_focus_tooltip())
	var drift := InputEventJoypadMotion.new()
	drift.axis_value = 0.1
	tooltip.note_input(InputEventMouseButton.new())
	tooltip.note_input(drift)
	assert_false(tooltip.allows_focus_tooltip(), "un eje de mando casi quieto no cuenta")
	drift.axis_value = 0.9
	tooltip.note_input(drift)
	assert_true(tooltip.allows_focus_tooltip(), "uno a fondo, sí")


func test_opening_a_window_with_a_tooltip_slot_does_not_show_the_tooltip() -> void:
	var tooltip: UITooltip = UITooltip.get_shared(tree)
	_nodes.append(tooltip.get_parent())
	tooltip.cancel()
	var window := UIWindow.new()
	window.centered = false
	var slot := UIIconSlot.new()
	slot.set_tooltip_info("Espada", "Corta")
	slot.bind_tooltip(tooltip)
	window.get_content().add_child(slot)
	_add(window)
	tooltip.note_input(_key(KEY_I))
	window.open()
	assert_true(slot.has_focus(), "la ventana enfoca su primer control")
	assert_false(tooltip.is_pending() or tooltip.is_showing(), "y su tooltip no tapa la ventana al abrirla")
	window.close()
	tooltip.cancel()


# --- UI-49: figura en reposo ---------------------------------------------------------------------

func test_the_character_figure_stands_instead_of_jumping() -> void:
	var figure: CharacterFigure = _add(CharacterFigure.new()) as CharacterFigure
	await wait_process_frames(3)
	var character: PlayerCharacter = figure.get_preview_character()
	if not assert_not_null(character, "la figura monta su personaje"):
		return
	assert_true(character.grounded, "con los pies en el suelo: nadie lo simula y el animador lo vería en el aire")
	var visual: HumanoidVisual = figure.get_visual()
	if not assert_not_null(visual):
		return
	await wait_process_frames(40)
	assert_eq(visual.get_animator().get_debug_state()["air_state"], "GROUNDED", "y el animador no pasa a la caída")


# --- UI-49: línea de ayuda ----------------------------------------------------------------------

func test_the_help_line_starts_hidden_and_f1_toggles_it() -> void:
	InputBindings.ensure_defaults()
	var hud: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_add(hud)
	await wait_process_frames(1)
	assert_false(hud.get_help_line().visible, "oculta por defecto")
	assert_eq(ClientSettings.get_default(ClientSettings.HELP_BAR), false)
	assert_true(ClientSettings.INTERFACE_IDS.has(ClientSettings.HELP_BAR), "con su ajuste en Interfaz")
	assert_true(hud.toggle_help_line(), "F1 la muestra")
	assert_true(hud.get_help_line().visible)
	assert_eq(ClientSettings.current().get_value(ClientSettings.HELP_BAR), true, "y lo recuerda en los ajustes")
	assert_false(hud.toggle_help_line(), "y la oculta")
	assert_false(hud.get_help_line().visible)
	assert_true(InputMap.has_action(&"toggle_help"), "F1 es una acción del cliente")
	ClientSettings.current().set_value(ClientSettings.HELP_BAR, true)
	assert_true(hud.get_help_line().visible, "el ajuste de Interfaz también la muestra")


func test_the_help_line_has_at_most_a_dozen_shortcuts_without_debug_or_release_mouse() -> void:
	var hints: Array[Dictionary] = UIHintBar.DEFAULT_HINTS.duplicate()
	hints.append_array(HUD.NET_HINTS_EXTRA)
	assert_true(hints.size() <= 12, "como mucho una docena de atajos (hay %d)" % hints.size())
	for hint: Dictionary in hints:
		assert_false([&"toggle_debug", &"toggle_cursor"].has(hint["action"]), "sin %s" % hint["action"])


# --- UI-50: viñeta de daño -----------------------------------------------------------------------

func test_the_damage_vignette_is_proportional_to_the_hit() -> void:
	var small: float = LowHealthVignette.flash_alpha_for(10, 1000)
	var medium: float = LowHealthVignette.flash_alpha_for(90, 1000)
	var large: float = LowHealthVignette.flash_alpha_for(250, 1000)
	assert_near(LowHealthVignette.flash_alpha_for(0, 1000), LowHealthVignette.FLASH_MIN_ALPHA, 1e-6, "el mínimo es 0,10")
	assert_true(small < medium and medium < large, "más daño, más alfa")
	assert_near(large, LowHealthVignette.FLASH_MAX_ALPHA, 1e-6, "un cuarto de la vida llega al máximo, 0,35")
	assert_near(LowHealthVignette.flash_alpha_for(900, 1000), LowHealthVignette.FLASH_MAX_ALPHA, 1e-6, "y no pasa de él")
	assert_true(LowHealthVignette.FLASH_MIN_ALPHA == 0.10 and LowHealthVignette.FLASH_MAX_ALPHA == 0.35)
	assert_true(medium < 0.25, "un golpe de 90 es de los pequeños (%.2f)" % medium)
	# Con la vida máxima de otro personaje, el mismo daño pesa distinto.
	assert_true(LowHealthVignette.flash_alpha_for(90, 400) > medium)


func test_a_hit_of_90_tints_at_most_ten_percent_of_the_screen() -> void:
	var vignette: LowHealthVignette = _add(LowHealthVignette.new()) as LowHealthVignette
	vignette.set_health_fraction(1.0)
	vignette.flash(90, 1000)
	var alpha: float = vignette.get_alpha()
	var coverage: float = LowHealthVignette.screen_coverage(alpha)
	assert_true(coverage <= 0.10, "un golpe de 90 tiñe %.1f %% de la pantalla (el límite es el 10 %%)" % (coverage * 100.0))
	assert_true(coverage > 0.0)
	assert_true(LowHealthVignette.screen_coverage(LowHealthVignette.FLASH_MAX_ALPHA) < 0.12,
			"y el golpe más fuerte tampoco pasa mucho de ese 10 %")


func test_the_damage_vignette_only_covers_the_edge() -> void:
	assert_eq(LowHealthVignette.gradient_alpha_at(0.0), 0.0, "el centro, transparente")
	assert_eq(LowHealthVignette.gradient_alpha_at(0.8), 0.0, "y casi hasta el borde")
	assert_true(LowHealthVignette.gradient_alpha_at(0.95) > 0.2 and LowHealthVignette.gradient_alpha_at(0.95) < 0.5)
	assert_true(LowHealthVignette.gradient_alpha_at(1.0) > 0.5, "en el borde de la pantalla ya es fuerte")
	assert_eq(LowHealthVignette.gradient_alpha_at(1.4), 1.0, "y en las esquinas, opaco")
	var vignette: LowHealthVignette = _add(LowHealthVignette.new()) as LowHealthVignette
	var texture: GradientTexture2D = vignette.texture as GradientTexture2D
	if assert_not_null(texture):
		var gradient: Gradient = texture.gradient
		var offsets: PackedFloat32Array = gradient.offsets
		assert_true(offsets[offsets.size() - 1] <= 1.0 and offsets[0] >= 0.0, "offsets válidos")
		assert_eq(gradient.get_color(0).a, 0.0)
		assert_eq(gradient.sample(0.5).a, 0.0, "el medio de la textura, transparente")


func test_the_vignette_does_not_draw_on_the_death_screen() -> void:
	var vignette: LowHealthVignette = _add(LowHealthVignette.new()) as LowHealthVignette
	vignette.set_health_fraction(0.0)
	vignette.advance(0.0)
	assert_true(vignette.get_alpha() > 0.0, "con la vida a cero se ve")
	vignette.set_suppressed(true)
	assert_eq(vignette.get_alpha(), 0.0, "apagada, no se ve")
	assert_false(vignette.visible)
	vignette.flash(500, 1000)
	assert_eq(vignette.get_alpha(), 0.0, "y los golpes no la encienden")
	vignette.set_suppressed(false)
	assert_true(vignette.get_alpha() > 0.0, "al reaparecer vuelve a poder dibujarse")


# --- UI-52: terreno del minimapa --------------------------------------------------------------

func test_the_terrain_fades_to_fog_at_the_edge_of_the_image_without_stretched_stripes() -> void:
	var fade: Vector2 = Vector2(0.04, 0.04)
	assert_eq(MinimapTerrain.terrain_weight(Vector2(0.5, 0.5), fade), 1.0, "en el centro, terreno")
	assert_eq(MinimapTerrain.terrain_weight(Vector2(0.04, 0.5), fade), 1.0, "hasta el comienzo del fundido")
	assert_eq(MinimapTerrain.terrain_weight(Vector2(0.0, 0.5), fade), 0.0, "en el borde de la imagen, niebla")
	for outside: Vector2 in [Vector2(-0.3, 0.5), Vector2(1.5, 0.5), Vector2(0.5, -2.0), Vector2(0.5, 1.2), Vector2(-1.0, 2.0)]:
		assert_eq(MinimapTerrain.terrain_weight(outside, fade), 0.0, "fuera de la imagen (%s) es niebla pura, no su borde estirado" % outside)
	var previous: float = 1.0
	for step: int in range(0, 41):
		var weight: float = MinimapTerrain.terrain_weight(Vector2(0.04 - float(step) * 0.001, 0.5), fade)
		assert_true(weight <= previous + 1e-6, "el fundido baja sin saltos")
		previous = weight
	assert_true(MinimapTerrain.terrain_weight(Vector2(0.02, 0.5), fade) > 0.0, "y a medias queda algo de terreno")
	assert_eq(MinimapTerrain.terrain_weight(Vector2(0.5, 0.01), fade), MinimapTerrain.terrain_weight(Vector2(0.01, 0.5), fade), "igual en los dos ejes")


func test_the_minimap_draws_its_terrain_with_a_shader_clamped_to_the_image() -> void:
	var map: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(map, "el mapa del Vado Gris"):
		return
	var minimap: Minimap = _add(Minimap.new()) as Minimap
	var terrain: MinimapTerrain = minimap.get_terrain()
	assert_not_null(terrain, "el minimapa tiene su terreno")
	assert_true(terrain.show_behind_parent, "detrás del aro, los iconos y el cono")
	assert_false(terrain.visible, "sin mapa ni jugador, no se ve")
	var shader_material: ShaderMaterial = terrain.get_terrain_material()
	var code: String = shader_material.shader.code
	assert_true(code.contains("filter_linear_mipmap"), "se muestrea con mipmaps")
	assert_true(code.contains("clamp(uv"), "con las coordenadas limitadas a la imagen")
	assert_true(code.contains("mix(fog_color"), "y fundido a niebla")
	terrain.set_map(map, map.load_texture())
	terrain.set_view(Vector3(0.0, 0.0, -138.0), 160.0)
	if terrain.get_terrain_material().get_shader_parameter(&"map_tex") == null:
		return
	assert_true(terrain.visible, "con mapa y jugador, sí")
	assert_vec_near(terrain.get_center_uv(), map.world_to_uv(Vector3(0.0, 0.0, -138.0)), 1e-6, "centrado en el jugador")
	assert_vec_near(terrain.get_half_uv(), MinimapTerrain.half_uv_for(map, 160.0), 1e-6)
	assert_near(terrain.get_half_uv().x, 80.0 / 320.0, 1e-6, "160 m de lado a lado sobre 320 m de mapa")
	assert_true(terrain.get_center_uv().y - terrain.get_half_uv().y < 0.0, "en el campamento, medio disco cae fuera de la imagen")


func test_the_map_image_is_imported_with_mipmaps() -> void:
	var import_text: String = FileAccess.get_file_as_string("res://assets/maps/vado_gris.png.import")
	assert_true(import_text.contains("mipmaps/generate=true"), "la imagen del mapa genera mipmaps (la reducción de 2,5 a 5 veces ya no moteará)")
	var terrain: MinimapTerrain = MinimapTerrain.new()
	assert_eq(terrain.texture_filter, CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	terrain.free()


# --- UI-54: marcadores del mundo ----------------------------------------------------------------

func _marker(id: StringName, kind: int, position: Vector3, realm: int = 0) -> WorldMarker:
	return WorldMarker.make(id, kind, String(id), position, Color.WHITE, realm)


func _item(marker: WorldMarker, screen: Vector2, objective: bool = false, on_edge: bool = false, alpha: float = 1.0) -> Dictionary:
	return {"marker": marker, "distance": 100.0, "screen": screen, "on_edge": on_edge, "angle": 0.0, "alpha": alpha,
			"objective": objective, "shown": false, "label": false}


func test_the_objective_is_the_active_circle_or_else_the_nearest_foreign_fort() -> void:
	var camp: WorldMarker = _marker(&"camp_1", WorldMarker.Kind.CAMP, Vector3(0.0, 0.0, -138.0), VARDHEIM)
	var gate: WorldMarker = _marker(&"gate_1", WorldMarker.Kind.GATE, Vector3(0.0, 0.0, -14.0))
	var own_fort: WorldMarker = _marker(&"fort_own", WorldMarker.Kind.FORT, Vector3(0.0, 0.0, -10.0), VARDHEIM)
	var enemy_fort: WorldMarker = _marker(&"fort_enemy", WorldMarker.Kind.FORT, Vector3(0.0, 0.0, 200.0), SOLMARCH)
	var circle: WorldMarker = _marker(&"circle_1", WorldMarker.Kind.CIRCLE, Vector3(0.0, 0.0, 5.0))
	var markers: Array[WorldMarker] = [camp, gate, own_fort, enemy_fort]
	var origin := Vector3(0.0, 0.0, -138.0)
	assert_eq(WorldMarkers.pick_objective(markers, origin, VARDHEIM), enemy_fort, "el fuerte que no es del propio reino, aunque esté más lejos")
	assert_eq(WorldMarkers.pick_objective(markers, origin, SOLMARCH), own_fort, "para el otro reino, el contrario")
	assert_eq(WorldMarkers.pick_objective(markers, origin, NetProtocol.Realm.NONE), own_fort, "sin reino, el más cercano")
	var only_own: Array[WorldMarker] = [camp, gate, own_fort]
	assert_eq(WorldMarkers.pick_objective(only_own, origin, VARDHEIM), own_fort, "si todos son suyos, el más cercano")
	markers.append(circle)
	assert_eq(WorldMarkers.pick_objective(markers, origin, VARDHEIM), circle, "con el círculo de captura activo, el círculo")
	var none: Array[WorldMarker] = [camp, gate]
	assert_null(WorldMarkers.pick_objective(none, origin, VARDHEIM), "sin fuerte ni círculo, ninguno")
	assert_null(WorldMarkers.pick_objective([] as Array[WorldMarker], origin, VARDHEIM))


func test_only_the_objective_is_drawn_by_default_and_without_a_name() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), Vector2(1400.0, 300.0), true)
	var gate: Dictionary = _item(_marker(&"gate", WorldMarker.Kind.GATE, Vector3.ZERO), Vector2(1500.0, 320.0))
	var camp: Dictionary = _item(_marker(&"camp", WorldMarker.Kind.CAMP, Vector3.ZERO), Vector2(300.0, 600.0))
	var items: Array[Dictionary] = [fort, gate, camp]
	WorldMarkers.select_shown(items, aim, false, false)
	assert_true(fort["shown"], "el objetivo, siempre")
	assert_false(fort["label"], "pero sin nombre mientras la mira está lejos")
	assert_false(gate["shown"], "la puerta no se dibuja")
	assert_false(camp["shown"], "ni el campamento")


func test_the_name_appears_when_the_aim_gets_close_to_the_icon() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), aim + Vector2(WorldMarkers.AIM_RADIUS - 1.0, 0.0), true)
	var gate: Dictionary = _item(_marker(&"gate", WorldMarker.Kind.GATE, Vector3.ZERO), aim + Vector2(0.0, WorldMarkers.AIM_RADIUS + 20.0))
	var items: Array[Dictionary] = [fort, gate]
	WorldMarkers.select_shown(items, aim, false, false)
	assert_true(fort["shown"] and fort["label"], "a menos de 80 px de la mira, con su nombre")
	assert_false(gate["shown"], "otro lugar a más de 80 px sigue sin dibujarse")
	gate["screen"] = aim + Vector2(30.0, -40.0)
	WorldMarkers.select_shown(items, aim, false, false)
	assert_true(gate["shown"] and gate["label"], "y uno que cae bajo la mira aparece, con su nombre")


func test_alt_shows_the_names_of_everything_on_screen_but_never_on_the_edge() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), Vector2(1400.0, 300.0), true)
	var camp: Dictionary = _item(_marker(&"camp", WorldMarker.Kind.CAMP, Vector3.ZERO), Vector2(300.0, 600.0))
	var pass_edge: Dictionary = _item(_marker(&"pass", WorldMarker.Kind.PASS, Vector3.ZERO), Vector2(44.0, 540.0), false, true)
	var items: Array[Dictionary] = [fort, camp, pass_edge]
	WorldMarkers.select_shown(items, aim, true, false)
	assert_true(fort["shown"] and fort["label"], "con Alt, el objetivo con nombre")
	assert_true(camp["shown"] and camp["label"], "y los lugares a la vista")
	assert_false(pass_edge["shown"], "pero lo que está fuera de la vista no se pega al borde")


func test_the_objective_stays_pinned_to_the_edge_when_it_is_out_of_view() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), Vector2(44.0, 540.0), true, true)
	var items: Array[Dictionary] = [fort]
	WorldMarkers.select_shown(items, aim, false, false)
	assert_true(fort["shown"], "el objetivo fuera de la vista, pegado al borde con su flecha")
	assert_false(fort["label"], "solo con la distancia")


func test_at_most_three_are_shown_and_the_closest_to_the_aim_win() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), Vector2(1400.0, 300.0), true)
	var items: Array[Dictionary] = [fort]
	# Cuatro lugares bajo la mira, separados en vertical para que no se pisen entre sí.
	var offsets: Array[Vector2] = [Vector2(10.0, -60.0), Vector2(20.0, -30.0), Vector2(50.0, 0.0), Vector2(70.0, 30.0)]
	for index: int in offsets.size():
		items.append(_item(_marker(StringName("camp_%d" % index), WorldMarker.Kind.CAMP, Vector3.ZERO), aim + offsets[index]))
	WorldMarkers.select_shown(items, aim, false, false)
	var shown: int = 0
	for item: Dictionary in items:
		shown += 1 if item["shown"] else 0
	assert_eq(shown, WorldMarkers.MAX_SHOWN, "tres en pantalla como mucho")
	assert_true(items[0]["shown"], "el objetivo cuenta")
	assert_true(items[2]["shown"] and items[3]["shown"], "y los dos más cercanos a la mira")
	assert_false(items[1]["shown"] or items[4]["shown"], "los demás, no")


func test_two_places_whose_labels_would_overlap_are_not_drawn_together() -> void:
	var aim := Vector2(960.0, 540.0)
	# El fuerte y un paso a 290 m detrás de él caen casi en el mismo punto de la pantalla.
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), aim + Vector2(-10.0, -10.0), true)
	var far_pass: Dictionary = _item(_marker(&"pass", WorldMarker.Kind.PASS, Vector3.ZERO), aim + Vector2(0.0, 5.0))
	var gate: Dictionary = _item(_marker(&"gate", WorldMarker.Kind.GATE, Vector3.ZERO), aim + Vector2(20.0, 12.0))
	var items: Array[Dictionary] = [fort, far_pass, gate]
	WorldMarkers.select_shown(items, aim, false, false)
	assert_true(fort["shown"])
	assert_false(far_pass["shown"], "el paso, justo encima del fuerte, no pisa su rótulo")
	assert_false(gate["shown"], "ni la puerta a menos de 24 px en vertical del fuerte")
	gate["screen"] = aim + Vector2(20.0, -10.0 + WorldMarkers.LABEL_SPACING.y + 1.0)
	WorldMarkers.select_shown(items, aim, false, false)
	assert_true(gate["shown"], "con sitio de sobra en vertical, sí")


func test_in_combat_only_the_objective_is_drawn_and_without_a_name() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), aim + Vector2(20.0, 10.0), true)
	var gate: Dictionary = _item(_marker(&"gate", WorldMarker.Kind.GATE, Vector3.ZERO), aim + Vector2(-30.0, 10.0))
	var items: Array[Dictionary] = [fort, gate]
	WorldMarkers.select_shown(items, aim, true, true)
	assert_true(fort["shown"], "el objetivo sigue")
	assert_false(fort["label"], "sin nombre, ni siquiera bajo la mira ni con Alt: ningún rótulo a menos de 150 px de la mira")
	assert_false(gate["shown"], "y nada más")


func test_faded_markers_are_not_drawn() -> void:
	var aim := Vector2(960.0, 540.0)
	var fort: Dictionary = _item(_marker(&"fort", WorldMarker.Kind.FORT, Vector3.ZERO), aim, true, false, 0.0)
	var items: Array[Dictionary] = [fort]
	WorldMarkers.select_shown(items, aim, false, false)
	assert_false(fort["shown"], "encima del lugar se desvanece y no se dibuja")


func test_the_combat_notice_lasts_five_seconds() -> void:
	var markers: WorldMarkers = _add(WorldMarkers.new()) as WorldMarkers
	assert_false(markers.is_in_combat())
	markers.notify_combat()
	assert_true(markers.is_in_combat())
	markers._process(WorldMarkers.COMBAT_SECONDS - 0.5)
	assert_true(markers.is_in_combat(), "dura unos 5 s")
	markers._process(1.0)
	assert_false(markers.is_in_combat())
