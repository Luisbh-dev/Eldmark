extends TestCase
## Tests of interface quality wave 3 (docs/quality.md; UI-02, ART-12, UI-55, UI-56, UI-18, UI-08,
## UI-41 and UI-50): own fonts throughout the client, drawn icons in the action bar and the statuses,
## mouse glyph inside the slot, nameplate stacking, faction mark, boss bar only while fighting, queued notices over
## a band, kill feed with icon and telegraph in amber.

const SCREEN: Vector2 = Vector2(1920.0, 1080.0)

var _nodes: Array[Node] = []


func before_each() -> void:
	InputBindings.ensure_defaults()


func after_each() -> void:
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


# --- UI-02: fuentes ---------------------------------------------------------------------------

func test_the_three_font_families_are_in_the_repo_with_their_licences() -> void:
	for path: String in [UIFonts.BODY_PATH, UIFonts.TITLE_PATH, UIFonts.MAP_PATH]:
		assert_true(ResourceLoader.exists(path), "existe %s" % path)
		assert_true(load(path) is FontFile, "%s loads as a font" % path)
	for licence: String in ["OFL-NotoSans.txt", "OFL-Cinzel.txt", "OFL-IMFellEnglishSC.txt"]:
		assert_true(FileAccess.file_exists("res://assets/fonts/" + licence), "the license %s" % licence)
	var credits: String = FileAccess.get_file_as_string("res://assets/LICENSES.md")
	for family: String in ["Noto Sans", "Cinzel", "IM Fell English SC"]:
		assert_true(credits.contains(family), "%s anotada en LICENSES.md" % family)


func test_the_theme_uses_noto_sans_for_text_and_cinzel_for_titles() -> void:
	var theme: Theme = load(UIThemeBuilder.THEME_PATH) as Theme
	assert_not_null(theme.default_font)
	assert_eq(theme.default_font.resource_path, UIFonts.BODY_PATH)
	var title_font: Font = theme.get_font(&"font", &"TitleLabel")
	assert_eq(title_font.resource_path, UIFonts.TITLE_PATH)


func test_no_client_script_draws_with_the_engine_font() -> void:
	var offenders: PackedStringArray = PackedStringArray()
	_scan_for_engine_font("res://scripts/client", offenders)
	assert_eq(offenders, PackedStringArray(), "ThemeDB.fallback_font reaparece en: %s" % ", ".join(offenders))


func _scan_for_engine_font(dir: String, offenders: PackedStringArray) -> void:
	for sub: String in DirAccess.get_directories_at(dir):
		_scan_for_engine_font(dir + "/" + sub, offenders)
	for file: String in DirAccess.get_files_at(dir):
		if not file.ends_with(".gd"):
			continue
		var text: String = FileAccess.get_file_as_string(dir + "/" + file)
		for line: String in text.split("\n"):
			if not line.strip_edges().begins_with("#") and line.contains("ThemeDB.fallback_font"):
				offenders.append(dir + "/" + file)
				break


func test_ui_fonts_gives_weights_of_the_variable_fonts() -> void:
	assert_true(UIFonts.body() is FontFile)
	var semibold: Font = UIFonts.body_semibold()
	assert_true(semibold is FontVariation, "the semibold comes from the wght axis")
	assert_eq((semibold as FontVariation).base_font, UIFonts.body())
	assert_true(UIFonts.title_bold() != UIFonts.title())


# --- ART-12: iconos ---------------------------------------------------------------------------

func test_every_weapon_ability_and_potion_has_a_drawn_icon() -> void:
	for weapon_name: StringName in [&"sword_shield", &"bow"]:
		var weapon_id: int = CombatCatalog.weapon_id(weapon_name)
		var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
		assert_true(CombatIcons.weapon_icon(weapon_id) is GameIcon, "icon of weapon %s" % weapon_name)
		for index: int in CombatState.ABILITY_SLOTS:
			var ability_id: int = weapon.ability_id(index)
			if ability_id != 0:
				assert_true(CombatIcons.ability_icon(ability_id) is GameIcon,
						"habilidad %d de %s dibujada" % [index, weapon_name])
	for potion: int in CombatCatalog.consumable_ids():
		assert_true(CombatIcons.ability_icon(potion) is GameIcon, "potion %d drawn" % potion)


func test_the_action_bar_shows_no_letters() -> void:
	var bar: ActionBar = _add(ActionBar.new()) as ActionBar
	var driver := MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), CombatCatalog.weapon_id(&"bow"),
			CombatState.pack_charges(3, 2))
	driver.step()
	bar.refresh(driver.c, driver.tick)
	for kind: int in ActionBar.Slot.size():
		var icon: Texture2D = bar.get_slot(kind).icon
		assert_true(icon is GameIcon, "slot %d carries a drawn icon (%s)" % [kind, icon])
	assert_true(bar.get_slot(ActionBar.Slot.PRIMARY).icon is GameIcon)
	# With the bow, the quick shot.
	driver.c.weapon_id = CombatCatalog.weapon_id(&"bow")
	bar.refresh(driver.c, driver.tick)
	assert_true(bar.get_slot(ActionBar.Slot.PRIMARY).icon is GameIcon, "the quick shot too")


func test_status_icons_use_the_native_small_variants() -> void:
	var bleed: int = CombatCatalog.status_id(&"bleed")
	var small: Texture2D = CombatIcons.status_icon(bleed, 14)
	assert_eq(small.get_width(), 14, "the plate uses the 14 px one")
	assert_eq(CombatIcons.status_icon(bleed, 26).get_width(), 26, "the own row, the 26 px one")
	assert_true(CombatIcons.status_icon(bleed) is GameIcon, "without a size, the large one")
	var regen: int = CombatCatalog.status_id(&"potion_regen")
	assert_eq(CombatIcons.status_icon(regen, 14).get_width(), 14, "regeneration uses the \"regen\" drawing")


func test_icons_are_bigger_inside_the_slot() -> void:
	assert_true(UIIconSlot.ICON_MARGIN <= 3.0, "the icon fills almost the whole slot (before it left 5 px)")


func test_the_compact_mouse_glyph_is_an_icon_and_fits_the_slot() -> void:
	var left: UIKeyGlyph = UIKeyGlyph.for_action(&"primary_attack", true)
	_add(left)
	assert_eq(left.get_mouse_icon(), MOUSE_BUTTON_LEFT, "the left click is drawn as a mouse")
	assert_true(left.get_combined_minimum_size().x <= 24.0, "and fits in the corner of the slot")
	var right: UIKeyGlyph = UIKeyGlyph.for_action(&"block", true)
	_add(right)
	assert_eq(right.get_mouse_icon(), MOUSE_BUTTON_RIGHT)
	var full: UIKeyGlyph = UIKeyGlyph.for_action(&"primary_attack", false)
	_add(full)
	assert_eq(full.get_mouse_icon(), MOUSE_BUTTON_NONE, "the normal glyph stays as text")


# --- UI-55: bloque inferior -------------------------------------------------------------------

func test_the_stamina_bar_never_disappears_but_rests_dim() -> void:
	var vitals: VitalsHud = _add(VitalsHud.new()) as VitalsHud
	vitals.set_stamina(1000, 1000)
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY + 1.0)
	assert_eq(vitals.get_stamina_alpha(), 0.0, "llena y quieta no destaca")
	assert_near(vitals.get_drawn_stamina_alpha(), VitalsHud.STAMINA_IDLE_ALPHA, 1e-6, "but it is drawn thin and faint")
	vitals.set_stamina(300, 1000)
	vitals.advance(0.5)
	assert_near(vitals.get_drawn_stamina_alpha(), 1.0, 1e-6, "when spent, at full opacity")


func test_the_bottom_block_is_one_compact_piece() -> void:
	var hud: HUD = (load("res://scenes/ui/hud.tscn") as PackedScene).instantiate() as HUD
	_add(hud)
	await wait_process_frames(2)
	var actions: Rect2 = hud.get_action_bar().get_global_rect()
	var vitals: Rect2 = hud.get_vitals().get_global_rect()
	assert_near(SCREEN.y, 1080.0, 0.1)
	var viewport_height: float = hud.get_viewport().get_visible_rect().size.y
	assert_near(viewport_height - actions.end.y, 24.0, 1.0, "the slots 24 px from the edge")
	assert_true(actions.position.y - vitals.end.y <= 10.0, "health and stamina right on top (%s, %s)" % [actions, vitals])
	assert_true(vitals.end.y <= actions.position.y, "without overlapping")
	var status_row: Rect2 = hud.get_status_row().get_global_rect()
	assert_true(status_row.end.y + 16.0 <= vitals.position.y + 1.0, "the effects above the bars, with room for the seconds")


# --- UI-56: placas ----------------------------------------------------------------------------

func test_overlapping_plates_are_stacked_upwards_by_priority() -> void:
	var rects: Array[Rect2] = [
		Rect2(100.0, 200.0, 100.0, 34.0), Rect2(120.0, 210.0, 100.0, 34.0), Rect2(500.0, 200.0, 100.0, 34.0),
	]
	var order: Array[int] = [0, 1, 2]
	var shifts: PackedFloat32Array = Nameplates.stack_shifts(rects, order, 2.0)
	assert_eq(shifts[0], 0.0, "the first does not move")
	assert_eq(shifts[2], 0.0, "the far one neither")
	assert_true(shifts[1] > 0.0, "the second rises")
	var moved := Rect2(rects[1].position - Vector2(0.0, shifts[1]), rects[1].size)
	assert_false(moved.intersects(rects[0]), "and no longer overlaps the first")
	assert_near(rects[0].position.y - moved.end.y, 2.0, 0.01, "with 2 px of air")


func test_a_pile_of_plates_ends_with_no_overlaps() -> void:
	var rects: Array[Rect2] = []
	var order: Array[int] = []
	for i: int in 6:
		rects.append(Rect2(300.0 + float(i) * 12.0, 400.0 + float(i) * 3.0, 110.0, 34.0))
		order.append(5 - i)
	var shifts: PackedFloat32Array = Nameplates.stack_shifts(rects, order, 2.0)
	var final: Array[Rect2] = []
	for i: int in 6:
		final.append(Rect2(rects[i].position - Vector2(0.0, shifts[i]), rects[i].size))
	for i: int in 6:
		for j: int in range(i + 1, 6):
			assert_false(final[i].intersects(final[j]), "plates %d and %d do not touch" % [i, j])


func test_stacked_plates_never_climb_beyond_the_cap() -> void:
	var rects: Array[Rect2] = []
	var order: Array[int] = []
	for i: int in 10:
		rects.append(Rect2(300.0, 400.0, 110.0, 34.0))
		order.append(i)
	var shifts: PackedFloat32Array = Nameplates.stack_shifts(rects, order, 2.0, 60.0)
	for i: int in 10:
		assert_true(shifts[i] <= 60.0, "plate %d rises %f" % [i, shifts[i]])


func test_a_plate_with_a_faction_mark_grows_its_content_and_distinguishes_ally_from_enemy() -> void:
	var plate: Nameplate = _add(Nameplate.new()) as Nameplate
	plate.configure(1, "Ana", Color.WHITE, true, true, 1.0, true, 1.0)
	var plain: Rect2 = plate.get_content_rect()
	plate.set_mark(Nameplate.Mark.ALLY, Color.GREEN)
	assert_true(plate.get_content_rect().size.y > plain.size.y, "the mark adds height")
	assert_eq(plate.get_mark(), Nameplate.Mark.ALLY)
	plate.set_mark(Nameplate.Mark.ENEMY, Color.RED)
	assert_eq(plate.get_mark(), Nameplate.Mark.ENEMY, "another shape for the enemy")
	plate.release()
	assert_eq(plate.get_mark(), Nameplate.Mark.NONE, "on release the plate is removed")
	plate.set_near(true)
	assert_true(plate.get_bar_size().x > Nameplate.BAR_SIZE.x, "up close the bar is bigger")


# --- UI-18: boss bar only while fighting -------------------------------------------------------

func test_the_boss_bar_waits_for_a_fight() -> void:
	var bar: BossBar = _add(BossBar.new()) as BossBar
	assert_false(bar.is_engaged(31), "without hits there is no fighting")
	bar.engage(31)
	assert_true(bar.is_engaged(31))
	assert_false(bar.is_engaged(32), "only with that boss")
	bar._process(BossBar.ENGAGE_SECONDS + 0.5)
	assert_false(bar.is_engaged(31), "and after a few seconds without hits it ends")


# --- UI-08: queued notices over a band ---------------------------------------------------------

func test_war_banners_show_one_at_a_time_on_a_band() -> void:
	var banners: WarBanners = _add(WarBanners.new()) as WarBanners
	assert_false(banners.is_band_visible(), "without notices there is no band")
	banners.add_banner("Primero", Color.WHITE)
	banners.add_banner("Segundo", Color.WHITE, true)
	assert_true(banners.is_band_visible())
	assert_eq(banners.get_banner_count(), 2, "one is visible and the other waits")
	assert_eq((banners.get_band().get_node(^"Fila/Texto") as Label).text, "Primero")
	# The second one's time does not run while it waits.
	banners.advance(1.0)
	assert_near(banners.get_banner_seconds_left(1), WarBanners.BIG_SECONDS, 1e-9)
	banners.advance(WarBanners.NORMAL_SECONDS)
	assert_eq(banners.get_banner_count(), 1, "the first goes away")
	assert_eq((banners.get_band().get_node(^"Fila/Texto") as Label).text, "Segundo", "and the second enters")
	banners.advance(WarBanners.BIG_SECONDS + 0.1)
	assert_false(banners.is_band_visible(), "with no more notices, the band hides")


func test_the_band_fades_only_at_the_ends_and_the_top_zones_do_not_collide() -> void:
	assert_near(WarBanners.band_alpha(WarBanners.NORMAL_SECONDS * 0.5, WarBanners.NORMAL_SECONDS), 1.0, 1e-6)
	assert_true(WarBanners.band_alpha(0.1, WarBanners.NORMAL_SECONDS) < 1.0, "it fades out on exit")
	assert_true(WarBanners.band_alpha(WarBanners.NORMAL_SECONDS - 0.1, WarBanners.NORMAL_SECONDS) < 1.0, "and on entry")
	assert_true(WarBanners.TOP_OFFSET < BossBar.TOP_OFFSET, "the band sits over the boss bar")
	assert_true(BossBar.TOP_OFFSET + 52.0 <= DownedNotice.TOP_OFFSET, "and the knocked-down notice, below both")


func test_the_band_and_the_boss_bar_and_the_downed_notice_never_overlap_on_screen() -> void:
	var screen := Control.new()
	screen.size = SCREEN
	_add(screen)
	screen.size = SCREEN
	var banners: WarBanners = _add(WarBanners.new(), screen) as WarBanners
	banners.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banners.add_banner("¡Vardheim ha capturado el Fuerte del Vado Gris!", Color.WHITE, true)
	var boss: BossBar = _add(BossBar.new(), screen) as BossBar
	boss.show_boss(7, "Capitán del Vado", 1.0)
	var notice: DownedNotice = _add(DownedNotice.new(), screen) as DownedNotice
	notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	notice.set_own_id(1)
	notice.update_view(true, 100, 0)
	await wait_process_frames(3)
	var band: Rect2 = banners.get_band().get_global_rect()
	var boss_rect: Rect2 = (boss.get_node(^"Columna") as Control).get_global_rect()
	var notice_rect: Rect2 = (notice.get_node(^"Columna") as Control).get_global_rect()
	assert_false(band.intersects(boss_rect), "band %s and boss bar %s" % [band, boss_rect])
	assert_false(band.intersects(notice_rect), "band %s and knocked-down notice %s" % [band, notice_rect])
	assert_false(boss_rect.intersects(notice_rect), "boss bar %s and knocked-down notice %s" % [boss_rect, notice_rect])
	for rect: Rect2 in [band, boss_rect]:
		assert_near(rect.get_center().x, SCREEN.x * 0.5, 1.0, "centrado en x = 960")


func test_the_band_stays_below_the_fort_panel_while_capturing() -> void:
	var screen := Control.new()
	screen.size = SCREEN
	_add(screen)
	screen.size = SCREEN
	var definition: FortressDefinition = load("res://data/fortresses/vado_gris.tres") as FortressDefinition
	var state: FortressState = FortressState.initial(definition, 100)
	state.phase = FortressState.Phase.CAPTURING
	state.capture_realm = NetProtocol.Realm.SOLMARCH
	var panel: CapturePanel = _add(CapturePanel.new(), screen) as CapturePanel
	panel.show_state(state, 0.4, "Fuerte del Vado Gris", 100)
	var banners: WarBanners = _add(WarBanners.new(), screen) as WarBanners
	banners.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banners.add_banner("Aviso", Color.WHITE, true)
	await wait_process_frames(3)
	var panel_rect: Rect2 = panel.get_global_rect()
	assert_true(panel_rect.size.y > 0.0, "the panel has a size")
	assert_true(panel_rect.end.y <= banners.get_band().get_global_rect().position.y,
			"band %s below panel %s" % [banners.get_band().get_global_rect(), panel_rect])


func test_nothing_in_the_war_hud_overlaps_the_tallest_fort_panel_at_both_resolutions() -> void:
	var definition: FortressDefinition = load("res://data/fortresses/vado_gris.tres") as FortressDefinition
	for screen_size: Vector2 in [SCREEN, Vector2(1280.0, 720.0)]:
		var screen := Control.new()
		screen.size = screen_size
		_add(screen)
		screen.size = screen_size
		# Tallest state: attacked, capture bar, "in the circle" row and gate bar all visible.
		var state: FortressState = FortressState.initial(definition, 100)
		state.phase = FortressState.Phase.CAPTURING
		state.capture_realm = NetProtocol.Realm.SOLMARCH
		state.under_attack_until_tick = 10000
		var panel: CapturePanel = _add(CapturePanel.new(), screen) as CapturePanel
		panel.show_state(state, 0.4, "Fuerte del Vado Gris", 100)
		var banners: WarBanners = _add(WarBanners.new(), screen) as WarBanners
		banners.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		banners.add_banner("Aviso", Color.WHITE, true)
		var boss: BossBar = _add(BossBar.new(), screen) as BossBar
		boss.show_boss(7, "Capitán del Vado", 1.0)
		var notice: DownedNotice = _add(DownedNotice.new(), screen) as DownedNotice
		notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		notice.set_own_id(1)
		notice.update_view(true, 100, 0)
		await wait_process_frames(3)
		var rects: Array[Rect2] = [
			banners.get_band().get_global_rect(),
			(boss.get_node(^"Columna") as Control).get_global_rect(),
			(notice.get_node(^"Columna") as Control).get_global_rect(),
		]
		var panel_rect: Rect2 = panel.get_global_rect()
		assert_true(panel.is_gate_shown(), "the gate bar is part of the measured panel")
		for rect: Rect2 in rects:
			assert_false(panel_rect.intersects(rect), "%s: panel %s overlaps %s" % [screen_size, panel_rect, rect])
		assert_true(ObjectiveLine.TOP_MARGIN + ObjectiveLine.HEIGHT <= WarBanners.TOP_OFFSET,
				"the objective line (which stands in for the panel) is above the band")
		screen.queue_free()


# --- UI-41: registro de bajas ------------------------------------------------------------------

func test_kill_lines_use_a_weapon_icon_when_there_is_one() -> void:
	var sword: int = CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"sword_light_1"))
	assert_true(KillFeed.icon_for_source(sword) is GameIcon, "a light slash carries the sword")
	var heavy: int = CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"sword_heavy"))
	assert_true(KillFeed.icon_for_source(heavy) is GameIcon)
	var bash: int = CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"shield_bash"))
	assert_true(KillFeed.icon_for_source(bash) is GameIcon, "an ability, its own")
	assert_null(KillFeed.icon_for_source(CombatSource.NONE), "without a source there is no icon")


# --- UI-50: amber telegraph --------------------------------------------------------------------

func test_npc_telegraphs_are_amber_and_not_the_damage_red() -> void:
	var amber: Color = UIPalette.TELEGRAPH
	assert_true(amber.h > 0.07 and amber.h < 0.13, "amber hue (%f)" % amber.h)
	var damage: Color = UIPalette.DANGER
	assert_true(absf(amber.h - damage.h) > 0.05, "different from the damage red")
	assert_eq(Color(TelegraphMarks.BASE_COLOR, 1.0), Color(amber, 1.0), "the mark uses the amber")
	assert_eq(Color(TelegraphMarks.FILL_COLOR, 1.0), Color(amber, 1.0))


func test_the_telegraph_edge_mesh_covers_circles_and_sectors() -> void:
	var circle: ArrayMesh = TelegraphMarks.build_edge_mesh(3.0, TAU, 40)
	assert_eq(circle.get_surface_count(), 1)
	var sector: ArrayMesh = TelegraphMarks.build_edge_mesh(3.0, deg_to_rad(100.0), 40)
	var circle_vertices: int = (circle.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var sector_vertices: int = (sector.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	assert_true(circle_vertices > 0 and sector_vertices > 0)
	var vertices: PackedVector3Array = sector.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for vertex: Vector3 in vertices:
		assert_true(vertex.length() <= 3.0 + 0.01, "the edge does not go beyond the radius")
