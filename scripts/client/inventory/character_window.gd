class_name CharacterWindow
extends UIWindow
## Ventana de personaje (tecla C; docs/progresion.md §11.1, UI-26): la figura 3D (un [SubViewport] con su propio
## mundo, un [PlayerCharacter] quieto con [HumanoidVisual], su apariencia y sus armas, que gira al arrastrar), las
## dos ranuras de arma (las otras cinco, en gris con «Próximamente»), nombre, reino, nivel y barra de XP, puntos
## de reino y de atributo, y la hoja de [CombatRules] (vida y resistencia máximas; en la fase 5 no cambia con el
## equipo).
## [br][br]
## Las casillas del equipo son [InventorySlotView] del contenedor EQUIPMENT y sus gestos (arrastrar, soltar, doble
## clic, soltar fuera) los resuelve la [InventoryWindow] que se le da en [method bind]: se arrastra de una ventana
## a otra. Las armas de la figura son las del estado de combate confirmado ([method set_weapons]), no las de la
## vista optimista del inventario: un rechazo nunca hace parpadear el arma.
## [br][br]
## La figura se monta la primera vez que se abre ([method ensure_preview]) y su [SubViewport] solo dibuja
## mientras la ventana está abierta. Solo cliente.

const TEXT_TITLE: String = "Personaje"
const TEXT_SOON: String = "Próximamente"
const TEXT_LEVEL: String = "Nivel %d"
const TEXT_XP: String = "%s / %s XP"
const TEXT_XP_CAP: String = "Nivel máximo"
const TEXT_REALM_POINTS: String = "Puntos de reino: %d"
const TEXT_ATTRIBUTE_POINTS: String = "Puntos de atributo: %d"
const TEXT_HEALTH: String = "Vida máxima: %d"
const TEXT_STAMINA: String = "Resistencia máxima: %d"
## Nombre de cada ranura del equipo ([enum InventoryState.EquipmentSlot]).
const SLOT_NAMES: Array[String] = ["Arma 1", "Arma 2", "Cabeza", "Torso", "Manos", "Piernas", "Pies"]
const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Tamaño (px) de la figura.
const PREVIEW_SIZE: Vector2i = Vector2i(220, 300)
## Radianes que gira la figura por píxel arrastrado.
const TURN_RATE: float = 0.012
## Cámara de la figura: de frente (el personaje mira hacia −Z) y a la altura del pecho. # TODO(arte): encuadre, luz y
## fondo provisionales hasta el visto bueno de la ventana (docs/progresion.md §16).
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


## Conecta la ventana con el inventario y el progreso del jugador y con la [InventoryWindow] que resuelve los
## gestos de sus casillas (también cuenta esta ventana como «dentro» al soltar).
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


## Nombre, reino (código de [enum NetProtocol.Realm]) y los 8 B de la apariencia del jugador (los del SPAWN
## propio; los que no valen caen a la de por defecto de su reino, [method AppearanceApplier.resolve]).
func set_identity(display_name: String, realm: int, appearance: PackedByteArray) -> void:
	_display_name = display_name
	_realm = realm
	_appearance_bytes = appearance
	if is_instance_valid(_visual):
		AppearanceApplier.apply_bytes(_visual, _appearance_bytes, _realm)
	refresh()


## Las armas de la figura: la activa y la de la otra ranura (ids de [CombatCatalog], del estado confirmado).
func set_weapons(weapon_id: int, alt_weapon_id: int) -> void:
	_weapon_id = weapon_id
	_alt_weapon_id = alt_weapon_id
	if is_instance_valid(_preview):
		_preview.combat.weapon_id = weapon_id
		_preview.combat.alt_weapon_id = alt_weapon_id


## Rehace las casillas del equipo y los textos.
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


## La casilla [param slot] del equipo ([enum InventoryState.EquipmentSlot]).
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


## El [HumanoidVisual] de la figura (null hasta [method ensure_preview]).
func get_preview_visual() -> HumanoidVisual:
	return _visual


## El [PlayerCharacter] quieto de la figura (null hasta [method ensure_preview]).
func get_preview_character() -> PlayerCharacter:
	return _preview


func get_preview_viewport() -> SubViewport:
	return _viewport


## Giro de la figura (radianes).
func get_preview_yaw() -> float:
	return _turntable.rotation.y if is_instance_valid(_turntable) else 0.0


## Gira la figura lo que corresponde a arrastrar [param pixels] en horizontal.
func rotate_preview(pixels: float) -> void:
	if is_instance_valid(_turntable):
		_turntable.rotation.y = wrapf(_turntable.rotation.y + pixels * TURN_RATE, -PI, PI)


## Monta la figura si aún no está (al abrir la ventana por primera vez) y la devuelve. Null si no hay árbol o
## no se pudo cargar el personaje.
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
