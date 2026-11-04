class_name CharacterWindow
extends UIWindow
## Character window (key C; docs/progresion.md §11.1, UI-26): the 3D figure (a [SubViewport] with its own
## world, a still [PlayerCharacter] with [HumanoidVisual], its appearance and its weapons, which turns when dragged), the
## two weapon slots (the other five, grayed out with "Próximamente", coming soon), name, realm, level and XP bar, realm
## and attribute points, and the [CombatRules] sheet (maximum health and stamina; in phase 5 it does not change with
## equipment).
## [br][br]
## The equipment slots are [InventorySlotView]s of the EQUIPMENT container and their gestures (drag, drop, double
## click, drop outside) are resolved by the [InventoryWindow] given in [method bind]: items are dragged from one window
## to the other. The figure's weapons are those of the confirmed combat state ([method set_weapons]), not those of the
## inventory's optimistic view: a rejection never makes the weapon flicker.
## [br][br]
## The figure is mounted the first time it is opened ([method ensure_preview]) and its [SubViewport] only draws
## while the window is open. Client only.

const TEXT_TITLE: String = "Personaje"
const TEXT_SOON: String = "Próximamente"
const TEXT_LEVEL: String = "Nivel %d"
const TEXT_XP: String = "%s / %s XP"
const TEXT_XP_CAP: String = "Nivel máximo"
const TEXT_REALM_POINTS: String = "Puntos de reino: %d"
const TEXT_ATTRIBUTE_POINTS: String = "Puntos de atributo: %d"
const TEXT_HEALTH: String = "Vida máxima: %d"
const TEXT_STAMINA: String = "Resistencia máxima: %d"
## Name of each equipment slot ([enum InventoryState.EquipmentSlot]).
const SLOT_NAMES: Array[String] = ["Arma 1", "Arma 2", "Cabeza", "Torso", "Manos", "Piernas", "Pies"]
const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Size (px) of the figure.
const PREVIEW_SIZE: Vector2i = Vector2i(220, 300)
## Radians the figure turns per dragged pixel.
const TURN_RATE: float = 0.012
## Camera of the figure: front-facing (the character looks toward −Z) and at chest height. # TODO(arte): framing, light and
## background are provisional until the window gets sign-off (docs/progresion.md §16).
const CAMERA_POSITION: Vector3 = Vector3(0.0, 1.1, -3.1)
const CAMERA_TARGET: Vector3 = Vector3(0.0, 0.92, 0.0)
const CAMERA_FOV: float = 38.0
const AMBIENT_COLOR: Color = Color(0.55, 0.55, 0.6, 1.0)

var _inventory: ClientInventory = null
var _progress: ClientProgress = null
var _gestures: InventoryWindow = null
var _slots: Array[InventorySlotView] = []
var _name_label: Label = null
var _realm_label: Label = null
var _level_label: Label = null
var _xp_bar: ProgressBar = null
var _xp_label: Label = null
var _realm_points_label: Label = null
var _attribute_label: Label = null
var _health_label: Label = null
var _stamina_label: Label = null
var _preview_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _turntable: Node3D = null
var _preview: PlayerCharacter = null
var _visual: HumanoidVisual = null
var _display_name: String = ""
var _realm: int = NetProtocol.Realm.NONE
var _appearance_bytes: PackedByteArray = PackedByteArray()
var _weapon_id: int = 0
var _alt_weapon_id: int = 0
var _dragging_preview: bool = false


func _init() -> void:
	super()
	name = "CharacterWindow"
	window_title = TEXT_TITLE
	var content: VBoxContainer = get_content()
	var top := HBoxContainer.new()
	top.add_theme_constant_override(&"separation", 14)
	content.add_child(top)
	_preview_container = SubViewportContainer.new()
	_preview_container.name = "Figura"
	_preview_container.stretch = true
	_preview_container.custom_minimum_size = Vector2(PREVIEW_SIZE)
	_preview_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_container.gui_input.connect(_on_preview_input)
	top.add_child(_preview_container)
	var sheet := VBoxContainer.new()
	sheet.name = "Hoja"
	sheet.custom_minimum_size = Vector2(220.0, 0.0)
	sheet.add_theme_constant_override(&"separation", 6)
	top.add_child(sheet)
	_name_label = _add_label(sheet, "Nombre", &"HeaderLabel")
	_realm_label = _add_label(sheet, "Reino", &"DimLabel")
	_level_label = _add_label(sheet, "Nivel", &"")
	_xp_bar = ProgressBar.new()
	_xp_bar.name = "BarraXP"
	_xp_bar.min_value = 0.0
	_xp_bar.max_value = 1.0
	_xp_bar.step = 0.0
	_xp_bar.show_percentage = false
	_xp_bar.custom_minimum_size = Vector2(0.0, 10.0)
	sheet.add_child(_xp_bar)
	_xp_label = _add_label(sheet, "XP", &"DimLabel")
	_realm_points_label = _add_label(sheet, "PuntosReino", &"")
	_attribute_label = _add_label(sheet, "PuntosAtributo", &"")
	sheet.add_child(HSeparator.new())
	_health_label = _add_label(sheet, "Vida", &"")
	_stamina_label = _add_label(sheet, "Resistencia", &"")
	content.add_child(HSeparator.new())
	var equipment := HBoxContainer.new()
	equipment.name = "Equipo"
	equipment.add_theme_constant_override(&"separation", 6)
	content.add_child(equipment)
	for slot: int in range(InventoryState.EQUIPMENT_SLOTS):
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override(&"separation", 2)
		equipment.add_child(cell)
		var view_slot := InventorySlotView.new()
		view_slot.name = "Ranura%d" % slot
		view_slot.container = InventoryState.ContainerId.EQUIPMENT
		view_slot.slot = slot
		view_slot.empty_title = SLOT_NAMES[slot]
		if slot >= InventoryState.OPEN_EQUIPMENT_SLOTS:
			view_slot.locked = true
			view_slot.empty_subtitle = TEXT_SOON
		cell.add_child(view_slot)
		var caption := Label.new()
		caption.theme_type_variation = &"DimLabel"
		caption.text = SLOT_NAMES[slot]
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_font_size_override(&"font_size", 12)
		cell.add_child(caption)
		_slots.append(view_slot)
	opened.connect(_on_opened)
	closed.connect(_on_closed)
	refresh()


func _ready() -> void:
	super()
	var tooltip: UITooltip = UITooltip.get_shared(get_tree())
	for view_slot: InventorySlotView in _slots:
		view_slot.bind_tooltip(tooltip)


## Connects the window to the player's inventory and progress and to the [InventoryWindow] that resolves the
## gestures of its slots (this window also counts as "inside" when dropping).
func bind(inventory: ClientInventory, progress: ClientProgress, gestures: InventoryWindow) -> void:
	if _inventory != null and _inventory.view_changed.is_connected(refresh):
		_inventory.view_changed.disconnect(refresh)
	if _progress != null and _progress.changed.is_connected(refresh):
		_progress.changed.disconnect(refresh)
	_inventory = inventory
	_progress = progress
	if _inventory != null:
		_inventory.view_changed.connect(refresh)
	if _progress != null:
		_progress.changed.connect(refresh)
	if gestures != _gestures:
		_gestures = gestures
		if _gestures != null:
			_gestures.add_drop_zone(self)
			for view_slot: InventorySlotView in _slots:
				_gestures.connect_slot(view_slot)
	refresh()


## Name, realm (code from [enum NetProtocol.Realm]) and the 8 B of the player's appearance (those from their own
## SPAWN; invalid ones fall back to their realm's default, [method AppearanceApplier.resolve]).
func set_identity(display_name: String, realm: int, appearance: PackedByteArray) -> void:
	_display_name = display_name
	_realm = realm
	_appearance_bytes = appearance
	if is_instance_valid(_visual):
		AppearanceApplier.apply_bytes(_visual, _appearance_bytes, _realm)
	refresh()


## The figure's weapons: the active one and the one in the other slot ([CombatCatalog] ids, from the confirmed state).
func set_weapons(weapon_id: int, alt_weapon_id: int) -> void:
	_weapon_id = weapon_id
	_alt_weapon_id = alt_weapon_id
	if is_instance_valid(_preview):
		_preview.combat.weapon_id = weapon_id
		_preview.combat.alt_weapon_id = alt_weapon_id


## Rebuilds the equipment slots and the texts.
func refresh() -> void:
	for view_slot: InventorySlotView in _slots:
		if _gestures != null and _inventory != null:
			_gestures.present_slot(view_slot)
		else:
			view_slot.show_item(null)
	_name_label.text = _display_name
	_realm_label.text = NetProtocol.realm_display_name(_realm) if _realm != NetProtocol.Realm.NONE else ""
	var level: int = _progress.get_level() if _progress != null else 1
	_level_label.text = TEXT_LEVEL % level
	_xp_bar.value = _progress.get_xp_fraction() if _progress != null else 0.0
	if _progress != null and _progress.get_xp_to_next() <= 0 and _progress.has_progress():
		_xp_label.text = TEXT_XP_CAP
	else:
		_xp_label.text = TEXT_XP % [str(_progress.get_xp_in_level() if _progress != null else 0),
				str(_progress.get_xp_to_next() if _progress != null else 0)]
	_realm_points_label.text = TEXT_REALM_POINTS % (_progress.get_realm_points() if _progress != null else 0)
	_attribute_label.text = TEXT_ATTRIBUTE_POINTS % (_progress.get_attribute_points() if _progress != null else 0)
	var rules: CombatRules = CombatCatalog.rules()
	_health_label.text = TEXT_HEALTH % rules.health_max
	_stamina_label.text = TEXT_STAMINA % rules.stamina_max


## Equipment slot [param slot] ([enum InventoryState.EquipmentSlot]).
func get_slot_view(slot: int) -> InventorySlotView:
	return _slots[slot] if slot >= 0 and slot < _slots.size() else null


func get_level_label() -> Label:
	return _level_label


func get_xp_bar() -> ProgressBar:
	return _xp_bar


func get_xp_label() -> Label:
	return _xp_label


func get_name_label() -> Label:
	return _name_label


func get_realm_points_label() -> Label:
	return _realm_points_label


func get_attribute_label() -> Label:
	return _attribute_label


func get_health_label() -> Label:
	return _health_label


## The figure's [HumanoidVisual] (null until [method ensure_preview]).
func get_preview_visual() -> HumanoidVisual:
	return _visual


## The figure's still [PlayerCharacter] (null until [method ensure_preview]).
func get_preview_character() -> PlayerCharacter:
	return _preview


func get_preview_viewport() -> SubViewport:
	return _viewport


## Turn of the figure (radians).
func get_preview_yaw() -> float:
	return _turntable.rotation.y if is_instance_valid(_turntable) else 0.0


## Turns the figure by the amount corresponding to dragging [param pixels] horizontally.
func rotate_preview(pixels: float) -> void:
	if is_instance_valid(_turntable):
		_turntable.rotation.y = wrapf(_turntable.rotation.y + pixels * TURN_RATE, -PI, PI)


## Mounts the figure if it is not there yet (when the window is first opened) and returns it. Null if there is no tree or
## the character could not be loaded.
func ensure_preview() -> HumanoidVisual:
	if is_instance_valid(_visual):
		return _visual
	if not is_inside_tree():
		return null
	_viewport = SubViewport.new()
	_viewport.name = "Mundo"
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.size = PREVIEW_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_preview_container.add_child(_viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = AMBIENT_COLOR
	_viewport.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 160.0, 0.0)
	_viewport.add_child(light)
	var camera := Camera3D.new()
	camera.fov = CAMERA_FOV
	_viewport.add_child(camera)
	camera.look_at_from_position(CAMERA_POSITION, CAMERA_TARGET, Vector3.UP)
	_turntable = Node3D.new()
	_turntable.name = "Giro"
	_viewport.add_child(_turntable)
	var scene: PackedScene = load(PLAYER_SCENE_PATH) as PackedScene
	_preview = scene.instantiate() as PlayerCharacter if scene != null else null
	if _preview == null:
		push_warning("[Eldmark] No se pudo montar la figura de la ventana de personaje")
		return null
	_preview.name = "Figura"
	# Nobody simulates this character: without this the animator always sees it in the air and shows it in the fall pose (UI-49).
	_preview.grounded = true
	_turntable.add_child(_preview)
	_visual = HumanoidVisual.install_replacing_placeholder(_preview)
	if _visual != null:
		AppearanceApplier.apply_bytes(_visual, _appearance_bytes, _realm)
	set_weapons(_weapon_id, _alt_weapon_id)
	return _visual


func _on_opened() -> void:
	ensure_preview()
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	refresh()


func _on_closed() -> void:
	_dragging_preview = false
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _on_preview_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		_dragging_preview = button.pressed
		_preview_container.accept_event()
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _dragging_preview:
		rotate_preview(motion.relative.x)
		_preview_container.accept_event()


static func _add_label(parent: Control, label_name: String, variation: StringName) -> Label:
	var label := Label.new()
	label.name = label_name
	label.theme_type_variation = variation
	parent.add_child(label)
	return label
