extends TestCase
## Regression tests of the HUD polish of wave 6: damage numbers that keep out of the notice strips, the gate bar
## text, stale war notices, world markers below the compass, the label pushed away from the crosshair and the
## knocked-down mark.

const NET_ID: int = 900
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const OTHER_FORT: int = 901


func _war(net_id: int, war_event: int, realm: int) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.war(net_id, 10, war_event, realm)


func test_damage_numbers_leave_the_reserved_strips() -> void:
	var strip := Rect2(Vector2(700.0, 260.0), Vector2(520.0, 108.0))
	var inside := Rect2(Vector2(900.0, 300.0), Vector2(60.0, 28.0))
	var moved: Rect2 = DamageNumbers.avoid_rects(inside, [strip])
	assert_false(moved.intersects(strip), "a number inside the strip is pushed out of it")
	assert_eq(moved.size, inside.size)
	var outside := Rect2(Vector2(100.0, 300.0), Vector2(60.0, 28.0))
	assert_eq(DamageNumbers.avoid_rects(outside, [strip]), outside, "one that is outside stays where it is")
	# It never jumps to the upper side: a number just below the strip stays below it.
	var rising := Rect2(Vector2(900.0, 360.0), Vector2(60.0, 28.0))
	assert_true(DamageNumbers.avoid_rects(rising, [strip]).position.y >= strip.end.y)


func test_damage_numbers_use_the_provider_when_placing() -> void:
	var numbers := DamageNumbers.new()
	numbers.size = Vector2(1920.0, 1080.0)
	tree.root.add_child(numbers)
	var strip := Rect2(Vector2(0.0, 0.0), Vector2(1920.0, 400.0))
	numbers.reserved_provider = func() -> Array: return [strip]
	var label: Label = numbers.add_number(1, Vector3.ZERO, 100)
	var drawn := Rect2(label.position + label.size * 0.5 - label.get_minimum_size() * 0.5, label.get_minimum_size())
	assert_false(drawn.intersects(strip), "the number is not left over the reserved strip")
	tree.root.remove_child(numbers)
	numbers.free()


func test_the_gate_bar_text_is_larger_and_outlined() -> void:
	var panel := CapturePanel.new()
	tree.root.add_child(panel)
	var gate: FractionBar = panel.find_child("Puerta", true, false) as FractionBar
	assert_not_null(gate)
	assert_true(gate.font_size >= 14, "gate text is at least 14 px")
	assert_true(gate.outline_size >= 5, "with a heavy outline")
	assert_true(gate.custom_minimum_size.y >= 18.0)
	tree.root.remove_child(panel)
	panel.free()


func test_a_capture_drops_the_waiting_notices_it_makes_obsolete() -> void:
	var banners := WarBanners.new()
	tree.root.add_child(banners)
	banners.show_war_event(_war(NET_ID, WarEvents.UNDER_ATTACK, VARDHEIM))
	banners.show_war_event(_war(NET_ID, WarEvents.CAPTURE_STARTED, VARDHEIM))
	banners.show_war_event(_war(OTHER_FORT, WarEvents.GATE_BROKEN, SOLMARCH))
	assert_eq(banners.get_banner_count(), 3)
	banners.show_war_event(_war(NET_ID, WarEvents.FORT_CAPTURED, VARDHEIM))
	var texts: PackedStringArray = banners.get_texts()
	assert_eq(texts.size(), 3, "the stale capture start leaves; the capture and the other fort's notice stay")
	assert_true(texts[0].contains("ataca"), "the visible notice is not cut halfway")
	assert_false(" ".join(texts).contains("empieza a capturar"))
	assert_true(texts[2].contains("capturado"))
	banners.clear()
	banners.show_war_event(_war(OTHER_FORT, WarEvents.CAPTURE_STARTED, SOLMARCH))
	banners.show_war_event(_war(OTHER_FORT, WarEvents.CAPTURE_STARTED, SOLMARCH))
	banners.show_war_event(_war(OTHER_FORT, WarEvents.FORT_RESET, 0))
	assert_eq(banners.get_banner_count(), 2, "a reset also drops the waiting capture notice")
	tree.root.remove_child(banners)
	banners.free()


func test_discard_stale_keeps_the_visible_one() -> void:
	var banners := WarBanners.new()
	tree.root.add_child(banners)
	banners.add_banner("visible", Color.WHITE, false, null, NET_ID, WarEvents.CAPTURE_STARTED)
	banners.add_banner("waiting", Color.WHITE, false, null, NET_ID, WarEvents.GATE_BROKEN)
	banners.add_banner("unknown", Color.WHITE)
	assert_eq(banners.discard_stale(NET_ID), 1)
	assert_eq(banners.get_texts(), PackedStringArray(["visible", "unknown"]))
	tree.root.remove_child(banners)
	banners.free()


func test_the_label_is_pushed_up_or_aside_never_down() -> void:
	var aim := Vector2(960.0, 540.0)
	var below := Rect2(Vector2(900.0, 600.0), Vector2(120.0, 18.0))
	var bounds := Rect2(Vector2(2.0, 92.0), Vector2(1916.0, 900.0))
	var pushed: Rect2 = WorldMarkers.push_from_aim(below, aim, WorldMarkers.LABEL_MIN_AIM_DISTANCE, bounds)
	var nearest := Vector2(clampf(aim.x, pushed.position.x, pushed.end.x), clampf(aim.y, pushed.position.y, pushed.end.y))
	assert_true(nearest.distance_to(aim) >= WorldMarkers.LABEL_MIN_AIM_DISTANCE - 0.01)
	assert_true(pushed.end.y <= aim.y + 0.01 or pushed.position.x >= aim.x + 149.0 or pushed.end.x <= aim.x - 149.0,
			"it ends above the crosshair or to one side, not on the character below it")
	assert_true(bounds.encloses(pushed))
	# If up does not fit, it goes to a side.
	var tight := Rect2(Vector2(2.0, 450.0), Vector2(1916.0, 300.0))
	var side: Rect2 = WorldMarkers.push_from_aim(Rect2(Vector2(900.0, 500.0), Vector2(120.0, 18.0)), aim, 150.0, tight)
	assert_true(tight.encloses(side))
	assert_true(side.position.x >= aim.x + 149.0 or side.end.x <= aim.x - 149.0)


func test_markers_stuck_to_the_top_stay_below_the_compass() -> void:
	var camera := Camera3D.new()
	tree.root.add_child(camera)
	camera.global_position = Vector3(0.0, 1.7, 0.0)
	camera.look_at(Vector3(0.0, 1.7, -10.0))
	camera.make_current()
	var projected: Dictionary = WorldMarkers.project(camera, Vector2(1920.0, 1080.0), Vector3(0.0, 400.0, -50.0),
			WorldMarkers.EDGE_MARGIN, WorldMarkers.BOTTOM_MARGIN, WorldMarkers.TOP_MARGIN)
	assert_true(bool(projected["on_edge"]))
	assert_true((projected["screen"] as Vector2).y >= Compass.TOP_MARGIN + Compass.HEIGHT + 20.0,
			"the icon and its distance are below the compass and its heading plate")
	tree.root.remove_child(camera)
	camera.free()


func test_downed_color_is_not_the_telegraph_amber() -> void:
	var downed: Color = CombatIcons.DOWNED_COLOR
	var amber: Color = UIPalette.TELEGRAPH
	assert_true(absf(downed.r - amber.r) + absf(downed.g - amber.g) + absf(downed.b - amber.b) > 0.8,
			"knocked down and telegraph have different colors")
	assert_eq(DownedNotice.DOWNED_COLOR, downed)
