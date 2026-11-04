class_name CharacterCreate
extends FrontScreen
## Character creation (UI-24, docs/plataforma.md §4.4 and §13.2), in four steps with the 3D figure on the
## right ([CharacterFigure], orbital camera with the mouse):
## [br]1. [b]Realm[/b]: cards with its capital, its people and the faction color; fixed to the account's
## if it already has one ([method setup]); Askarra appears as "Próximamente" (Coming soon) (§0).
## [br]2. [b]Body and appearance[/b]: body, head, hair, beard, marks, skin, hair color and eyes, each with
## "◀ ▶" among what the realm's people allow and what fits the body, and "Aleatorio" (Random)
## ([method CharacterAppearance.random]). With what exists today from ART-19 (one body, one head, one
## hairstyle and one beard; ART-20 will bring more): whatever has no options appears without arrows.
## [br]3. [b]Starter template[/b]: the templates that can be chosen (PRG-07, the
## [code]starter_templates[/code] section), with their weapons and potions; it is the kit for the first
## entry (progresion.md §2.5).
## [br]4. [b]Name[/b]: validated with [NameRules] while typing and with [code]name-check[/code] after
## [constant NAME_CHECK_DELAY_S] s without typing ([signal name_check_requested] and
## [method set_name_check]).
## [br][br]
## "Crear" (Create) emits [signal create_requested] with the body of
## [code]POST /v1/worlds/{w}/characters[/code] (the appearance in bytes: [AccountFlow] passes it to
## base64). Esc goes back one step (on the first, to the selection). Client only.

## Pressed "Crear" (Create) with everything valid. [param body]:
## [code]{name, realm, race_id, appearance, starter_template_id}[/code].
signal create_requested(body: Dictionary)
## Asks the platform to check whether [param display_name] is free (after 500 ms without typing).
signal name_check_requested(display_name: String)
## Returned to the selection (Esc on the first step or "Volver" (Back)).
signal canceled

enum Step { REALM, APPEARANCE, TEMPLATE, NAME }

const STEP_TITLES: Array[String] = ["1. Reino", "2. Apariencia", "3. Plantilla", "4. Nombre"]
const NAME_CHECK_DELAY_S: float = 0.5
## Realms that cannot be chosen yet (§0: Vado Gris does not admit Askarra).
const COMING_SOON: Array[StringName] = [RealmCatalog.ASKARRA]
const CAPITALS: Dictionary = {RealmCatalog.VARDHEIM: "Isenholm", RealmCatalog.SOLMARCH: "Valcorin",
		RealmCatalog.ASKARRA: "Kassar"}
const LORE: Dictionary = {
	RealmCatalog.VARDHEIM: "Clanes del norte, fiordos y glaciares. Juraron custodiar el trono y fallaron.",
	RealmCatalog.SOLMARCH: "El reino del Alba: valles, catedrales y una fe luminosa que roza el fanatismo.",
	RealmCatalog.ASKARRA: "Forjas de ceniza en cañones rojos; su tierra se muere y solo las Brasas la sostienen.",
}
const TEXT_SOON: String = "Próximamente"
const TEXT_LOCKED: String = "Tu cuenta es de otro reino"
const TEXT_PICK_REALM: String = "Elige un reino"
const TEXT_NAME_TAKEN: String = "Ese nombre ya está en uso"
const TEXT_NAME_FREE: String = "Nombre libre"
const TEXT_NAME_CHECKING: String = "Comprobando el nombre…"
## Appearance fields, in row order, with their text.
const FIELDS: Array[StringName] = [&"body", &"head", &"hair", &"beard", &"marks", &"skin", &"hair_color", &"eyes"]
const FIELD_TITLES: Dictionary = {&"body": "Cuerpo", &"head": "Cabeza", &"hair": "Pelo", &"beard": "Barba",
		&"marks": "Marcas", &"skin": "Piel", &"hair_color": "Color de pelo", &"eyes": "Ojos"}
const NONE_TITLES: Dictionary = {&"hair": "Sin pelo", &"beard": "Sin barba", &"marks": "Sin marcas"}

var _step: Step = Step.REALM
var _step_label: Label = null
var _pages: Array[Control] = []
var _realm_buttons: Dictionary[StringName, Button] = {}
var _realm_group: ButtonGroup = ButtonGroup.new()
var _field_labels: Dictionary[StringName, Label] = {}
var _field_buttons: Dictionary[StringName, Array] = {}
var _random_button: Button = null
var _template_buttons: Dictionary[StringName, Button] = {}
var _template_group: ButtonGroup = ButtonGroup.new()
var _name_edit: LineEdit = null
var _name_reason: Label = null
var _name_timer: Timer = null
var _back_button: Button = null
var _next_button: Button = null
var _create_button: Button = null
var _figure: CharacterFigure = null
var _account_realm: StringName = &""
var _realm: StringName = &""
var _appearance: CharacterAppearance = null
var _template: StringName = &""
var _checked_name: String = ""
var _name_available: bool = true
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init() -> void:
	super()
	name = "CharacterCreate"
	_rng.randomize()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 40)
	add_child(margin)
	var root := HBoxContainer.new()
	root.add_theme_constant_override(&"separation", 24)
	margin.add_child(root)
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"WindowPanel"
	panel.custom_minimum_size = Vector2(560.0, 0.0)
	root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", ROW_SEPARATION)
	panel.add_child(column)
	column.add_child(make_label("Crear personaje", &"HeaderLabel"))
	_step_label = make_label("", &"DimLabel")
	_step_label.name = "Pasos"
	column.add_child(_step_label)
	_notice_label = make_label("", &"ErrorLabel")
	_notice_label.name = "Aviso"
	_notice_label.visible = false
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_notice_label)
	var pages := VBoxContainer.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(pages)
	_pages = [_build_realm_page(), _build_appearance_page(), _build_template_page(), _build_name_page()]
	for page: Control in _pages:
		pages.add_child(page)
	_back_button = make_button("Volver", 120.0, &"GhostButton")
	_back_button.name = "Atras"
	_next_button = make_button("Siguiente", 160.0)
	_next_button.name = "Siguiente"
	_create_button = make_button("Crear", 180.0)
	_create_button.name = "Crear"
	add_button_row(column, [_back_button], [_next_button, _create_button])
	_figure = CharacterFigure.new()
	_figure.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_figure.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_figure)
	_name_timer = Timer.new()
	_name_timer.one_shot = true
	_name_timer.wait_time = NAME_CHECK_DELAY_S
	_name_timer.timeout.connect(_on_name_timer)
	add_child(_name_timer)
	_busy_controls = [_back_button]
	_back_button.pressed.connect(back)
	_next_button.pressed.connect(next)
	_create_button.pressed.connect(try_create)
	_show_step(Step.REALM)


func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree() and event.is_action_pressed(&"ui_cancel"):
		back()
		get_viewport().set_input_as_handled()


## Starts a creation: [param account_realm] is the account's realm in the world ([RealmCatalog] id; empty
## if it does not have one yet: one of the open ones can be chosen). Returns to the first step with
## everything at its default.
func setup(account_realm: StringName) -> void:
	_account_realm = account_realm if RealmCatalog.is_realm(account_realm) else &""
	_realm = &""
	_appearance = null
	_template = AccountFlow.first_starter_template()
	_checked_name = ""
	_name_available = true
	_name_edit.text = ""
	set_notice("")
	for realm_id: StringName in _realm_buttons:
		var button: Button = _realm_buttons[realm_id]
		var allowed: bool = is_realm_selectable(realm_id)
		button.disabled = not allowed
		button.tooltip_text = "" if allowed else (TEXT_SOON if COMING_SOON.has(realm_id) else TEXT_LOCKED)
		button.set_pressed_no_signal(false)
	if not _account_realm.is_empty():
		select_realm(_account_realm)
	for template_id: StringName in _template_buttons:
		_template_buttons[template_id].set_pressed_no_signal(template_id == _template)
	_show_step(Step.REALM)


## true if [param realm_id] can be chosen: open and, if the account already has a realm, that one.
func is_realm_selectable(realm_id: StringName) -> bool:
	if not RealmCatalog.is_realm(realm_id) or COMING_SOON.has(realm_id):
		return false
	return _account_realm.is_empty() or realm_id == _account_realm


## Chooses realm [param realm_id] (if possible): the appearance switches to the default of its people.
func select_realm(realm_id: StringName) -> bool:
	if not is_realm_selectable(realm_id):
		return false
	_realm = realm_id
	for id: StringName in _realm_buttons:
		_realm_buttons[id].set_pressed_no_signal(id == _realm)
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	_appearance = CharacterAppearance.default_for(catalog, _race_index())
	_refresh_appearance()
	_refresh_state()
	return true


func get_realm() -> StringName:
	return _realm


## The step it is on.
func get_step() -> Step:
	return _step


## Moves to the next step if the current one is complete. Returns true if it advanced.
func next() -> bool:
	if _busy or _step == Step.NAME or not _step_complete(_step):
		return false
	_show_step((_step + 1) as Step)
	return true


## Goes back one step; on the first, emits [signal canceled].
func back() -> void:
	if _busy:
		return
	if _step == Step.REALM:
		canceled.emit()
		return
	_show_step((_step - 1) as Step)


## The options of [param field] (one of [constant FIELDS]) for the chosen people and their body: the
## values it can take in the 8 B (with 0 = "none" for hair, beard and marks when allowed).
func options_for(field: StringName) -> PackedInt32Array:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var index: int = _race_index()
	if index < 0 or _appearance == null:
		return PackedInt32Array()
	var race: RaceDefinition = catalog.races[index]
	var body: int = _appearance.body
	match field:
		&"body":
			return _existing(race.bodies, catalog.bodies.size())
		&"head":
			return AppearanceCatalog.fitting_indices(race.heads, catalog.heads, body)
		&"hair":
			return _optional(AppearanceCatalog.fitting_indices(race.hairs, catalog.hairs, body), race.allows_no_hair)
		&"beard":
			return _optional(AppearanceCatalog.fitting_indices(race.beards, catalog.beards, body),
					race.allows_no_beard)
		&"marks":
			return _optional(AppearanceCatalog.fitting_indices(race.marks, catalog.marks, body), true)
		&"skin":
			return _existing(race.skin_tones, catalog.skin_tones.size())
		&"hair_color":
			return _existing(race.hair_colors, catalog.hair_colors.size())
		&"eyes":
			return _existing(race.eye_colors, catalog.eye_colors.size())
	return PackedInt32Array()


## Moves [param field] to the next option ([param step] 1) or the previous (−1), wrapping around.
func cycle(field: StringName, step: int) -> void:
	if _appearance == null:
		return
	var options: PackedInt32Array = options_for(field)
	if options.is_empty():
		return
	var current: int = options.find(int(_appearance.get(field)))
	var next_index: int = posmod((current if current >= 0 else 0) + step, options.size())
	_appearance.set(field, options[next_index])
	if field == &"body":
		_fit_to_body()
	_refresh_appearance()


## A random appearance of the chosen people ([method CharacterAppearance.random]).
func randomize_appearance() -> void:
	var random: CharacterAppearance = CharacterAppearance.random(AppearanceCatalog.shared(), _race_index(), _rng)
	if random != null:
		_appearance = random
		_refresh_appearance()


## The chosen appearance (null before choosing a realm).
func get_appearance() -> CharacterAppearance:
	return _appearance


## The text shown by the row of [param field] ("Castaño" (chestnut)...).
func get_field_text(field: StringName) -> String:
	var label: Label = _field_labels.get(field)
	return label.text if label != null else ""


## Chooses the starter template [param template_id] (if offered).
func select_template(template_id: StringName) -> bool:
	if not _template_buttons.has(template_id):
		return false
	_template = template_id
	for id: StringName in _template_buttons:
		_template_buttons[id].set_pressed_no_signal(id == _template)
	_refresh_state()
	return true


func get_template() -> StringName:
	return _template


## Ids of the templates on offer, in order.
func get_template_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for id: StringName in _template_buttons:
		ids.append(id)
	return ids


## Writes [param display_name] into the name field (as if typed).
func set_name_text(display_name: String) -> void:
	_name_edit.text = display_name
	_on_name_changed(display_name)


## The [code]name-check[/code] response for [param display_name]: [param available] and, if not, the
## reason text.
func set_name_check(display_name: String, available: bool, reason_text: String = "") -> void:
	if display_name != _name_edit.text.strip_edges():
		return
	_checked_name = display_name
	_name_available = available
	if available:
		_name_reason.text = TEXT_NAME_FREE
		_name_reason.theme_type_variation = &"DimLabel"
	else:
		_name_reason.text = reason_text if not reason_text.is_empty() else TEXT_NAME_TAKEN
		_name_reason.theme_type_variation = &"ErrorLabel"
	_refresh_state()


## The reason under the name (from [NameRules] or from [code]name-check[/code]).
func get_name_reason_text() -> String:
	return _name_reason.text


## Emits the name check right away (what the 500 ms timer does).
func flush_name_check() -> void:
	_name_timer.stop()
	_on_name_timer()


## The body of [code]POST /v1/worlds/{w}/characters[/code] with what was chosen.
func build_body() -> Dictionary:
	return {
		"name": _name_edit.text.strip_edges(),
		"realm": _realm,
		"race_id": AccountFlow.race_id_for(_realm),
		"appearance": _appearance.encode() if _appearance != null else PackedByteArray(),
		"starter_template_id": _template,
	}


## Emits [signal create_requested] if everything is valid. Returns true if it emitted it.
func try_create() -> bool:
	if _busy or _step != Step.NAME or not _all_complete():
		return false
	create_requested.emit(build_body())
	return true


## Returns to the name step with [param text] as the reason (a platform [code]name_taken[/code]).
func show_name_error(text: String) -> void:
	_show_step(Step.NAME)
	_checked_name = _name_edit.text.strip_edges()
	_name_available = false
	_name_reason.text = text
	_name_reason.theme_type_variation = &"ErrorLabel"
	_refresh_state()


func get_name_edit() -> LineEdit:
	return _name_edit


func get_realm_button(realm_id: StringName) -> Button:
	return _realm_buttons.get(realm_id)


func get_template_button(template_id: StringName) -> Button:
	return _template_buttons.get(template_id)


func get_next_button() -> Button:
	return _next_button


func get_create_button() -> Button:
	return _create_button


func get_figure() -> CharacterFigure:
	return _figure


# --- Construction ---------------------------------------------------------------------------------

func _build_realm_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "Reino"
	page.add_theme_constant_override(&"separation", ROW_SEPARATION)
	for realm_id: StringName in RealmCatalog.REALM_IDS:
		var race: RaceDefinition = AppearanceCatalog.shared().race_for_realm(realm_id)
		var button := Button.new()
		button.name = String(realm_id).capitalize()
		button.toggle_mode = true
		button.button_group = _realm_group
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.custom_minimum_size = Vector2(0.0, 96.0)
		var lines: PackedStringArray = PackedStringArray([RealmCatalog.display_name(realm_id),
				"Capital: %s · Pueblo: %s" % [CAPITALS.get(realm_id, "—"),
						race.display_name if race != null else "—"], LORE.get(realm_id, "")])
		if COMING_SOON.has(realm_id):
			lines[0] += " · %s" % TEXT_SOON
		button.text = "\n".join(lines)
		var color: Color = RealmCatalog.color_of(realm_id)
		button.add_theme_color_override(&"font_color", color)
		button.add_theme_color_override(&"font_pressed_color", color.lightened(0.3))
		button.add_theme_color_override(&"font_disabled_color", color.darkened(0.5))
		button.pressed.connect(func() -> void: select_realm(realm_id))
		page.add_child(button)
		_realm_buttons[realm_id] = button
	return page


func _build_appearance_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "Apariencia"
	page.add_theme_constant_override(&"separation", 8)
	for field: StringName in FIELDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		var title := make_label(FIELD_TITLES[field])
		title.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
		row.add_child(title)
		var previous := make_button("◀", 44.0, &"GhostButton")
		previous.name = "%s_anterior" % field
		previous.pressed.connect(func() -> void: cycle(field, -1))
		row.add_child(previous)
		var value := make_label("")
		value.name = "%s_valor" % field
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(value)
		var following := make_button("▶", 44.0, &"GhostButton")
		following.name = "%s_siguiente" % field
		following.pressed.connect(func() -> void: cycle(field, 1))
		row.add_child(following)
		page.add_child(row)
		_field_labels[field] = value
		_field_buttons[field] = [previous, following]
	_random_button = make_button("Aleatorio", 160.0)
	_random_button.name = "Aleatorio"
	_random_button.pressed.connect(randomize_appearance)
	page.add_child(_random_button)
	var hint := make_label("Arrastra la figura para girarla; la rueda acerca y aleja.", &"DimLabel")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(hint)
	return page


func _build_template_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "Plantilla"
	page.add_theme_constant_override(&"separation", ROW_SEPARATION)
	var help := make_label("Tu equipo de salida: las armas y las pociones con las que empiezas.", &"DimLabel")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(help)
	for template: EquipmentTemplate in AccountFlow.starter_templates():
		var template_id: int = CombatCatalog.template_id(template.id)
		var button := Button.new()
		button.name = String(template.id).capitalize().replace(" ", "")
		button.toggle_mode = true
		button.button_group = _template_group
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.custom_minimum_size = Vector2(0.0, 72.0)
		button.text = "%s\n%s" % [CombatText.template_title(template_id), CombatText.template_summary(template_id)]
		var id: StringName = template.id
		button.pressed.connect(func() -> void: select_template(id))
		page.add_child(button)
		_template_buttons[template.id] = button
	return page


func _build_name_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "NombrePagina"
	page.add_theme_constant_override(&"separation", ROW_SEPARATION)
	_name_edit = make_line_edit("de 3 a 16 letras, empezando por mayúscula", false, 32)
	_name_edit.name = "Nombre"
	add_row(page, "Nombre", _name_edit)
	_name_reason = make_label("", &"DimLabel")
	_name_reason.name = "Motivo"
	_name_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_name_reason)
	var rules := make_label("El nombre: %s." % NameRules.rules_summary(), &"DimLabel")
	rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(rules)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(func(_text: String) -> void: try_create())
	return page


# --- State ----------------------------------------------------------------------------------------

func _show_step(step: Step) -> void:
	_step = step
	for i: int in range(_pages.size()):
		_pages[i].visible = i == int(step)
	var titles: PackedStringArray = PackedStringArray()
	for i: int in range(STEP_TITLES.size()):
		titles.append("[%s]" % STEP_TITLES[i] if i == int(step) else STEP_TITLES[i])
	_step_label.text = "   ".join(titles)
	_back_button.text = "Volver" if step == Step.REALM else "Atrás"
	if step == Step.NAME and is_inside_tree():
		_name_edit.grab_focus()
	_refresh_appearance()
	_refresh_state()


func _step_complete(step: Step) -> bool:
	match step:
		Step.REALM:
			return not _realm.is_empty()
		Step.APPEARANCE:
			return _appearance != null and _appearance.validate(AppearanceCatalog.shared(),
					RealmCatalog.code_of(_realm), AccountFlow.race_id_for(_realm))
		Step.TEMPLATE:
			return _template_buttons.has(_template)
		Step.NAME:
			var display_name: String = _name_edit.text.strip_edges()
			if not NameRules.is_valid(display_name):
				return false
			return _checked_name != display_name or _name_available
	return false


func _all_complete() -> bool:
	for step: int in range(Step.size()):
		if not _step_complete(step as Step):
			return false
	return true


func _refresh_state() -> void:
	super()
	if _next_button == null:
		return
	_next_button.visible = _step != Step.NAME
	_create_button.visible = _step == Step.NAME
	_next_button.disabled = _busy or not _step_complete(_step)
	_create_button.disabled = _busy or not _all_complete()
	_next_button.tooltip_text = TEXT_PICK_REALM if _step == Step.REALM and _realm.is_empty() else ""


func _refresh_appearance() -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	for field: StringName in FIELDS:
		var options: PackedInt32Array = options_for(field)
		var buttons: Array = _field_buttons[field]
		for button: Variant in buttons:
			(button as Button).disabled = options.size() <= 1
		_field_labels[field].text = _value_text(catalog, field) if _appearance != null else "—"
	_random_button.disabled = _appearance == null
	if _appearance != null and is_instance_valid(_figure):
		_figure.show_appearance_object(_appearance, RealmCatalog.code_of(_realm))


# When the body changes, whatever no longer fits switches to the first option that does.
func _fit_to_body() -> void:
	for field: StringName in FIELDS:
		if field == &"body":
			continue
		var options: PackedInt32Array = options_for(field)
		if not options.is_empty() and not options.has(int(_appearance.get(field))):
			_appearance.set(field, options[0])


func _value_text(catalog: AppearanceCatalog, field: StringName) -> String:
	var value: int = int(_appearance.get(field))
	match field:
		&"body":
			return _entry_name(catalog.bodies, value)
		&"head":
			return _entry_name(catalog.heads, value)
		&"hair":
			return NONE_TITLES[field] if value == CharacterAppearance.NONE else _entry_name(catalog.hairs, value - 1)
		&"beard":
			return NONE_TITLES[field] if value == CharacterAppearance.NONE else _entry_name(catalog.beards, value - 1)
		&"marks":
			return NONE_TITLES[field] if value == CharacterAppearance.NONE else _entry_name(catalog.marks, value - 1)
		&"skin":
			return _entry_name(catalog.skin_tones, value)
		&"hair_color":
			return _entry_name(catalog.hair_colors, value)
		&"eyes":
			return _entry_name(catalog.eye_colors, value)
	return ""


func _race_index() -> int:
	if _realm.is_empty():
		return -1
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(_realm)
	return catalog.race_index(race.id) if race != null else -1


static func _entry_name(entries: Array, index: int) -> String:
	if index < 0 or index >= entries.size() or entries[index] == null:
		return "—"
	var display: String = str(entries[index].get(&"display_name"))
	return display if not display.is_empty() else String(entries[index].get(&"id"))


static func _existing(allowed: PackedInt32Array, size: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for index: int in allowed:
		if index >= 0 and index < size and not result.has(index):
			result.append(index)
	return result


static func _optional(indices: PackedInt32Array, none_allowed: bool) -> PackedInt32Array:
	var result := PackedInt32Array()
	if none_allowed:
		result.append(CharacterAppearance.NONE)
	for index: int in indices:
		result.append(index + 1)
	return result


func _on_name_changed(_text: String) -> void:
	var display_name: String = _name_edit.text.strip_edges()
	var reason: int = NameRules.validate(display_name)
	_name_timer.stop()
	if display_name.is_empty():
		_name_reason.text = ""
	elif reason != NameRules.Reason.OK:
		_name_reason.text = NameRules.reason_text(reason)
		_name_reason.theme_type_variation = &"ErrorLabel"
	else:
		_name_reason.text = TEXT_NAME_CHECKING
		_name_reason.theme_type_variation = &"DimLabel"
		if is_inside_tree():
			_name_timer.start()
	_refresh_state()


func _on_name_timer() -> void:
	var display_name: String = _name_edit.text.strip_edges()
	if NameRules.is_valid(display_name) and display_name != _checked_name:
		name_check_requested.emit(display_name)
