class_name SettingsMenu
extends UIWindow
## Settings window (UI-16): one tab per group (graphics, audio, camera and interface) with one control
## per [ClientSettings] setting, generated from its table: toggle, dropdown list or slider with its value
## next to it.
## [br][br]
## Each change goes to [method ClientSettings.set_value]; whoever applies the settings live
## ([ClientServices]) listens to [signal ClientSettings.changed]. The window also listens to that signal
## to keep the controls up to date when the value changes elsewhere (on restore). When it is closed the
## changes are saved ([method ClientSettings.save_if_dirty]).
## [br][br]
## "Restaurar pestaña" (Restore tab) returns the settings of the open tab to their default value and
## "Restaurar todo" (Restore all) those of all of them (with confirmation if given a
## [UIConfirmDialog]). The resolution can only be chosen in windowed mode. It opens with F10
## ([ClientServices]) and, like every [UIWindow], closes with Esc and frees the cursor while open.
## [br][br]
## Client only.

## A change was requested from the window (the control of [param id] changed the setting).
signal setting_changed(id: StringName)

const WINDOW_WIDTH: float = 700.0
## Minimum height of the tabs, so that the window does not change size when switching from one to another.
const TABS_HEIGHT: float = 340.0
const LABEL_WIDTH: float = 250.0
const VALUE_WIDTH: float = 120.0
const TITLE_TEXT: String = "Ajustes"
const RESTORE_TAB_TEXT: String = "Restaurar pestaña"
const RESTORE_ALL_TEXT: String = "Restaurar todo"
const CLOSE_TEXT_BUTTON: String = "Cerrar"
const CONFIRM_TITLE: String = "Restaurar todos los ajustes"
const CONFIRM_MESSAGE: String = "Todos los ajustes volverán a sus valores por defecto."

var _settings: ClientSettings = null
var _confirm: UIConfirmDialog = null
var _tabs: TabContainer = null
var _restore_tab_button: Button = null
var _restore_all_button: Button = null
var _close_button_bottom: Button = null
# Setting -> its control (CheckButton, OptionButton or HSlider) and its value text.
var _controls: Dictionary = {}
var _value_labels: Dictionary = {}
var _syncing: bool = false


func _init() -> void:
	# Creates the window's title bar and content column.
	super()
	window_title = TITLE_TEXT
	custom_minimum_size = Vector2(WINDOW_WIDTH, 0.0)


## Assembles the window with the settings of [param settings]. [param confirm] is the confirmation
## dialog for "Restaurar todo" (Restore all) (without it, it restores directly). It can be called once.
func setup(settings: ClientSettings, confirm: UIConfirmDialog = null) -> void:
	_settings = settings
	_confirm = confirm
	if _confirm != null:
		_confirm.confirmed.connect(_on_restore_confirmed)
	_build()
	_settings.changed.connect(_on_settings_changed)
	closed.connect(_on_closed)
	UISounds.hook_all(self)


## The settings the window edits.
func get_settings() -> ClientSettings:
	return _settings


## The control of setting [param id] (null if it does not exist).
func get_control(id: StringName) -> Control:
	return _controls.get(id, null) as Control


## The text with the value of setting [param id] (null if it is not a range).
func get_value_label(id: StringName) -> Label:
	return _value_labels.get(id, null) as Label


func get_tabs() -> TabContainer:
	return _tabs


## Identifier of the open tab ([constant ClientSettings.TAB_GRAPHICS]...).
func get_current_tab_id() -> StringName:
	return ClientSettings.TABS[_tabs.current_tab]


## Opens tab [param tab] ([constant ClientSettings.TAB_AUDIO]...).
func show_tab(tab: StringName) -> void:
	var index: int = ClientSettings.TABS.find(tab)
	if index >= 0:
		_tabs.current_tab = index


func get_restore_tab_button() -> Button:
	return _restore_tab_button


func get_restore_all_button() -> Button:
	return _restore_all_button


## Returns the open tab's settings to their default value.
func restore_current_tab() -> void:
	_settings.reset_tab(get_current_tab_id())


## Returns all the settings to their default value; with a confirmation dialog, it opens it and waits for
## its response.
func restore_all() -> void:
	if _confirm != null:
		_confirm.open(CONFIRM_TITLE, CONFIRM_MESSAGE, RESTORE_ALL_TEXT, "Cancelar", true)
	else:
		_on_restore_confirmed()


## Opens the window with the controls up to date and focus on the first setting of the open tab.
func open() -> void:
	if _settings != null:
		_sync_all()
	super()
	if _tabs != null:
		UIFocus.focus_first(_tabs.get_current_tab_control())


# --- Assembly ---------------------------------------------------------------------------------

func _build() -> void:
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(WINDOW_WIDTH - 40.0, TABS_HEIGHT)
	get_content().add_child(_tabs)
	for tab: StringName in ClientSettings.TABS:
		var page: VBoxContainer = VBoxContainer.new()
		page.name = String(ClientSettings.TAB_NAMES[tab])
		page.add_theme_constant_override(&"separation", 10)
		_tabs.add_child(page)
	for spec: Dictionary in ClientSettings.get_schema():
		var page: Control = _tabs.get_child(ClientSettings.TABS.find(spec["tab"])) as Control
		page.add_child(_make_row(spec))
	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 10)
	get_content().add_child(buttons)
	_restore_tab_button = Button.new()
	_restore_tab_button.text = RESTORE_TAB_TEXT
	_restore_tab_button.pressed.connect(restore_current_tab)
	buttons.add_child(_restore_tab_button)
	_restore_all_button = Button.new()
	_restore_all_button.text = RESTORE_ALL_TEXT
	_restore_all_button.pressed.connect(restore_all)
	buttons.add_child(_restore_all_button)
	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	_close_button_bottom = Button.new()
	_close_button_bottom.text = CLOSE_TEXT_BUTTON
	_close_button_bottom.pressed.connect(close)
	buttons.add_child(_close_button_bottom)
	_sync_all()


func _make_row(spec: Dictionary) -> HBoxContainer:
	var id: StringName = spec["id"]
	var row: HBoxContainer = HBoxContainer.new()
	row.name = String(id)
	row.add_theme_constant_override(&"separation", 14)
	var label: Label = Label.new()
	label.text = spec["label"]
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	row.add_child(label)
	var control: Control = null
	match int(spec["kind"]):
		ClientSettings.Kind.BOOL:
			var toggle: CheckButton = CheckButton.new()
			toggle.toggled.connect(func(pressed: bool) -> void: _on_control_changed(id, pressed))
			control = toggle
		ClientSettings.Kind.CHOICE:
			var option: OptionButton = OptionButton.new()
			option.custom_minimum_size = Vector2(260.0, 0.0)
			for text: String in spec["labels"]:
				option.add_item(text)
			option.item_selected.connect(func(index: int) -> void:
				_on_control_changed(id, (spec["values"] as Array)[index]))
			control = option
		_:
			var slider: HSlider = HSlider.new()
			slider.min_value = float(spec["min"])
			slider.max_value = float(spec["max"])
			slider.step = float(spec["step"])
			slider.custom_minimum_size = Vector2(260.0, 0.0)
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			slider.value_changed.connect(func(value: float) -> void:
				_on_control_changed(id, value))
			control = slider
			var value_label: Label = Label.new()
			value_label.custom_minimum_size = Vector2(VALUE_WIDTH, 0.0)
			value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value_label.theme_type_variation = &"DimLabel"
			_value_labels[id] = value_label
	control.name = "Control"
	row.add_child(control)
	if _value_labels.has(id):
		row.add_child(_value_labels[id])
	_controls[id] = control
	return row


# --- Synchronization between controls and settings --------------------------------------------

func _on_control_changed(id: StringName, value: Variant) -> void:
	if _syncing:
		return
	if _settings.set_value(id, value):
		setting_changed.emit(id)


func _on_settings_changed(id: StringName, _value: Variant) -> void:
	_sync_control(id)
	_refresh_dependencies()


func _sync_all() -> void:
	for id: StringName in _controls:
		_sync_control(id)
	_refresh_dependencies()


# Sets the control of [param id] to the setting's value without firing its signal.
func _sync_control(id: StringName) -> void:
	var control: Control = _controls.get(id, null) as Control
	if control == null:
		return
	var value: Variant = _settings.get_value(id)
	_syncing = true
	if control is CheckButton:
		(control as CheckButton).button_pressed = bool(value)
	elif control is OptionButton:
		var spec: Dictionary = ClientSettings.get_spec(id)
		(control as OptionButton).select((spec["values"] as Array).find(value))
	elif control is HSlider:
		(control as HSlider).value = float(value)
		(_value_labels[id] as Label).text = ClientSettings.format_value(id, value)
	_syncing = false


# The resolution only applies in windowed mode.
func _refresh_dependencies() -> void:
	var resolution: OptionButton = get_control(ClientSettings.RESOLUTION) as OptionButton
	if resolution != null:
		resolution.disabled = int(_settings.get_value(ClientSettings.WINDOW_MODE)) \
				!= ClientSettings.MODE_WINDOWED


func _on_restore_confirmed() -> void:
	_settings.reset_all()


func _on_closed() -> void:
	_settings.save_if_dirty()
