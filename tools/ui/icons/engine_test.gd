extends SceneTree
## Prueba en el motor de los iconos de la interfaz (ART-12), a la escala real del HUD y sin reescalar.
##
## Dibuja con las clases del juego, no con una imitación: [UIIconSlot] para las barras de acciones (casilla
## de 52 px, glifo de tecla arriba a la izquierda, contador abajo a la derecha, reutilización y estado
## apagado) y [StatusIcons.StatusIcon] para los efectos (30 px la fila propia, 18 px las placas de nombre).
## Cada icono es una textura de dos capas ([LayeredIcon]): el fondo de su categoría y la figura encima, que es
## como se entregan (assets/ui/icons/backgrounds y la figura suelta). Las casillas dibujan el icono con su
## margen de siempre, así que se ve lo que pasaría al enchufarlos tal cual.
##
## Hace falta un motor con ventana (no vale --headless) porque lee los píxeles de lo que dibuja la GPU:
##   godot --path . -s res://tools/ui/icons/engine_test.gd -- <captura_hud.png> <carpeta_de_salida>
## La captura (1920 x 1080, por ejemplo build/calidad/interfaz/hud_en_pelea_03.png) es el fondo. Escribe:
##   motor_barra_espada.png, motor_barra_arco.png  la barra en su sitio sobre la captura, recorte 1:1
##   motor_tablero.png                             todas las filas rotuladas sobre un panel oscuro, 1:1

const ICON_DIR: String = "res://assets/ui/icons"
const MANIFEST: String = "res://build/iconos/capas/manifest.json"
const VIEW_SIZE: Vector2i = Vector2i(1920, 1080)
## Posición de la barra de acciones en hud_en_pelea_03.png (esquina de cada casilla de 52 px).
const BAR_X: Array[int] = [669, 727, 785, 865, 923, 981, 1061, 1119, 1199]
const BAR_Y: int = 842
const BAR_KEYS: Array[String] = ["Clic izq.", "Clic der.", "Ctrl", "1", "2", "3", "R", "T", "Q"]
const SWORD_BAR: Array[String] = ["sword_light", "block", "dodge", "shield_bash", "shield_rush",
		"shield_wall", "potion_health", "potion_stamina", "weapon_sword_shield"]
const BOW_BAR: Array[String] = ["bow_quick", "bow_drawn", "dodge", "bow_volley", "bow_slowing_shot",
		"bow_evasive_shot", "potion_health", "potion_stamina", "weapon_bow"]
const COUNTS: Dictionary = {"potion_health": 6, "potion_stamina": 5}
const STATES: Array[String] = ["bleed", "regen", "stun", "slowed", "knockback", "downed", "rooted"]
const BENEFICIAL: Array[String] = ["regen"]
## Recorte de la captura que se enseña en las muestras de la barra.
const BAR_CROP: Rect2i = Rect2i(600, 800, 720, 125)
const BOARD_CROP: Rect2i = Rect2i(540, 696, 840, 352)

var _categories: Dictionary = {}
var _backgrounds: Dictionary = {}
var _figures: Dictionary = {}
var _capture: ImageTexture = null
var _out_dir: String = "res://build/iconos"


## Icono de dos capas: el fondo estirado a todo el rectángulo y la figura encima. Es una [Texture2D], así
## que entra en cualquier casilla y el tinte de «apagado» y el barrido de reutilización le valen igual.
class LayeredIcon extends Texture2D:
	var background: Texture2D = null
	var figure: Texture2D = null
	var side: int = 128

	func _get_width() -> int:
		return side

	func _get_height() -> int:
		return side

	func _has_alpha() -> bool:
		return false

	func _draw(canvas_item: RID, pos: Vector2, modulate: Color, transpose: bool) -> void:
		_draw_rect(canvas_item, Rect2(pos, Vector2(side, side)), false, modulate, transpose)

	func _draw_rect(canvas_item: RID, rect: Rect2, _tile: bool, modulate: Color, transpose: bool) -> void:
		background.draw_rect(canvas_item, rect, false, modulate, transpose)
		figure.draw_rect(canvas_item, rect, false, modulate, transpose)

	func _draw_rect_region(canvas_item: RID, rect: Rect2, _src_rect: Rect2, modulate: Color,
			transpose: bool, _clip_uv: bool) -> void:
		_draw_rect(canvas_item, rect, false, modulate, transpose)


func _initialize() -> void:
	_run()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var capture_path: String = args[0] if args.size() > 0 else ""
	_out_dir = args[1] if args.size() > 1 else _out_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	_load_manifest()
	var capture: Image = Image.load_from_file(capture_path) if not capture_path.is_empty() else null
	if capture == null:
		capture = Image.create_empty(VIEW_SIZE.x, VIEW_SIZE.y, false, Image.FORMAT_RGBA8)
		capture.fill(Color(0.34, 0.27, 0.2))
	_capture = ImageTexture.create_from_image(capture)
	await _render(_build_bar.bind(SWORD_BAR), BAR_CROP, "motor_barra_espada.png")
	await _render(_build_bar.bind(BOW_BAR), BAR_CROP, "motor_barra_arco.png")
	await _render(_build_board, BOARD_CROP, "motor_tablero.png")
	quit(0)


func _load_manifest() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if data is Dictionary:
		for job: Dictionary in (data as Dictionary)["jobs"]:
			if not bool(job["small"]):
				_categories[String(job["base"])] = String(job["category"])


func _texture(path: String) -> ImageTexture:
	var image: Image = Image.load_from_file(path)
	if image == null:
		push_error("No se pudo leer %s" % path)
		return null
	return ImageTexture.create_from_image(image)


func _background_of(category: String) -> ImageTexture:
	if not _backgrounds.has(category):
		_backgrounds[category] = _texture("%s/backgrounds/%s.png" % [ICON_DIR, category])
	return _backgrounds[category]


func _figure_of(path: String) -> ImageTexture:
	if not _figures.has(path):
		_figures[path] = _texture(path)
	return _figures[path]


## Icono grande de [param icon_id] (figura de 128 px sobre el fondo de su categoría).
func _big_icon(icon_id: String) -> LayeredIcon:
	var icon := LayeredIcon.new()
	icon.background = _background_of(String(_categories.get(icon_id, "mundo")))
	icon.figure = _figure_of("%s/%s.png" % [ICON_DIR, icon_id])
	return icon


## Variante pequeña de un estado: la figura nativa de [param side] px sobre el fondo del estado.
func _small_icon(state_id: String, side: int) -> LayeredIcon:
	var icon := LayeredIcon.new()
	var category: String = "estado_bueno" if BENEFICIAL.has(state_id) else "estado_malo"
	icon.background = _background_of(category)
	icon.figure = _figure_of("%s/small/%s_%d.png" % [ICON_DIR, state_id, side])
	icon.side = side
	return icon


func _render(builder: Callable, crop: Rect2i, file_name: String) -> void:
	var view := SubViewport.new()
	view.size = VIEW_SIZE
	view.transparent_bg = false
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var background := TextureRect.new()
	background.texture = _capture
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.position = Vector2.ZERO
	background.size = Vector2(VIEW_SIZE)
	view.add_child(background)
	builder.call(view)
	for _i: int in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = view.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	image.get_region(crop).save_png(_out_dir.path_join(file_name))
	print("escrito %s" % _out_dir.path_join(file_name))
	view.queue_free()
	await process_frame


# --- Piezas -------------------------------------------------------------------------------------

func _add_slot(parent: Node, icon: Texture2D, pos: Vector2, key_text: String = "", count: int = 0) -> UIIconSlot:
	var slot := UIIconSlot.new()
	slot.position = pos
	slot.size = UIIconSlot.SLOT_SIZE
	parent.add_child(slot)
	slot.icon = icon
	if not key_text.is_empty():
		slot.key_action = &"ui_accept"
		var glyph: UIKeyGlyph = slot.get_glyph()
		glyph.action = &""
		glyph.text_override = key_text
	slot.count = count
	return slot


func _add_bar_row(parent: Node, ids: Array[String], y: int) -> Array[UIIconSlot]:
	var slots: Array[UIIconSlot] = []
	for index: int in ids.size():
		slots.append(_add_slot(parent, _big_icon(ids[index]), Vector2(BAR_X[index], y), BAR_KEYS[index],
				int(COUNTS.get(ids[index], 0))))
	return slots


func _build_bar(view: SubViewport, ids: Array[String]) -> void:
	_add_bar_row(view, ids, BAR_Y)


func _add_label(parent: Node, text: String, pos: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.add_theme_font_size_override(&"font_size", 15)
	label.add_theme_color_override(&"font_color", Color(0.93, 0.91, 0.86))
	label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override(&"outline_size", 4)
	parent.add_child(label)


func _add_status(parent: Node, state_id: String, side: int, pos: Vector2) -> void:
	var status := StatusIcons.StatusIcon.new()
	status.icon = _small_icon(state_id, side - 4)
	status.harmful = not BENEFICIAL.has(state_id)
	status.compact = side < 24
	status.seconds_left = 0 if status.compact else 6
	status.custom_minimum_size = Vector2(side, side)
	status.size = Vector2(side, side)
	status.position = pos
	parent.add_child(status)


func _build_board(view: SubViewport) -> void:
	var panel := ColorRect.new()
	panel.color = Color(0.03, 0.035, 0.045, 0.97)
	panel.position = Vector2(BOARD_CROP.position)
	panel.size = Vector2(BOARD_CROP.size)
	view.add_child(panel)
	var left: float = float(BAR_X[0])
	var y: float = 708.0
	_add_label(view, "Barra de espada y escudo (UIIconSlot, casilla de 52 px, icono a 42 px)", Vector2(left, y))
	_add_bar_row(view, SWORD_BAR, int(y) + 22)
	y += 84.0
	_add_label(view, "Barra de arco (Descarga en reutilización, Disparo ralentizador apagado)", Vector2(left, y))
	var bow_slots: Array[UIIconSlot] = _add_bar_row(view, BOW_BAR, int(y) + 22)
	bow_slots[3].set_cooldown(4.0, 10.0)
	bow_slots[4].enabled = false
	y += 84.0
	_add_label(view, "Efectos: fila propia a 30 px (izquierda) y placas de nombre a 18 px (derecha), sin reescalar", Vector2(left, y))
	var x: float = left
	for state_id: String in STATES:
		_add_status(view, state_id, 30, Vector2(x, y + 24.0))
		x += 33.0
	x += 40.0
	for state_id: String in STATES:
		_add_status(view, state_id, 18, Vector2(x, y + 30.0))
		x += 21.0
	y += 70.0
	_add_label(view, "Los mismos efectos con el icono grande, en casillas de 52 px", Vector2(left, y))
	x = left
	for state_id: String in STATES:
		_add_slot(view, _big_icon(state_id), Vector2(x, y + 22.0))
		x += 58.0
