class_name UISounds
extends RefCounted
## UI sound hooks (UI-09): hover, press, confirm, cancel, open and close a window, error and a slider's
## "tick". They sound through the [constant AudioBuses.UI] bus via the [AudioDirector].
## [br][br]
## There are no real sounds yet ([code]assets/audio/ui/[/code] is empty): [method play] looks for
## [code]assets/audio/ui/<event>.ogg[/code] (or [code].wav[/code]) the first time each event is requested
## and, if it does not exist, nothing plays but the hook works just the same (it is counted with
## [method get_play_count], which the tests use). When the Kenney ones arrive (ART-11, CC0) it will be
## enough to drop them in with those names. [method set_stream] sets one by hand (tests, or a different
## sound theme).
## [br][br]
## [method hook_button] and [method hook_all] connect the buttons and sliders of a control tree to their
## sounds; the common components ([UIIconSlot], [UIConfirmDialog], [UIWindow]) call [method play] on their
## own.
## [br][br]
## Client only.

const HOVER: StringName = &"hover"
const CLICK: StringName = &"click"
const CONFIRM: StringName = &"confirm"
const CANCEL: StringName = &"cancel"
const OPEN: StringName = &"open"
const CLOSE: StringName = &"close"
const ERROR: StringName = &"error"
const TICK: StringName = &"tick"

## All the UI sound events.
const EVENTS: Array[StringName] = [HOVER, CLICK, CONFIRM, CANCEL, OPEN, CLOSE, ERROR, TICK]
## Folder of the sounds and the extensions that are tried, in order.
const SOUND_DIR: String = "res://assets/audio/ui"
const EXTENSIONS: Array[String] = ["ogg", "wav"]
## Volume (dB) of each event; those not listed, 0. Hover and the tick are discreet.
const VOLUMES_DB: Dictionary = {HOVER: -9.0, TICK: -11.0}
## Minimum milliseconds between two plays of the same event (those not listed, no limit): scrolling
## through a list must not sound like a machine gun.
const MIN_REPEAT_MSEC: Dictionary = {HOVER: 60, TICK: 45}
const HOOKED_META: StringName = &"ui_sounds_hooked"

## Mutes all the hooks (player setting or tests).
static var muted: bool = false

# Event -> AudioStream (null if there is no sound for it).
static var _streams: Dictionary = {}
static var _looked_up: Dictionary = {}
static var _counts: Dictionary = {}
static var _last_msec: Dictionary = {}


## Requests the sound for [param event]. Returns true if it counts as played (it was neither muted nor
## throttled for repeating too soon); it actually sounds if there is an [AudioDirector] and a sound for the
## event.
static func play(event: StringName) -> bool:
	if muted:
		return false
	var minimum: int = int(MIN_REPEAT_MSEC.get(event, 0))
	if minimum > 0:
		var now: int = Time.get_ticks_msec()
		if now - int(_last_msec.get(event, -1000000)) < minimum:
			return false
		_last_msec[event] = now
	_counts[event] = get_play_count(event) + 1
	var director: AudioDirector = AudioDirector.get_instance()
	var stream: AudioStream = get_stream(event)
	if director != null and stream != null:
		director.play_ui(stream, float(VOLUMES_DB.get(event, 0.0)))
	return true


## Sound for [param event]: the one set with [method set_stream] or, if none, the one from
## [code]assets/audio/ui/[/code] (null if there is none).
static func get_stream(event: StringName) -> AudioStream:
	if not _looked_up.has(event):
		_looked_up[event] = true
		for extension: String in EXTENSIONS:
			var path: String = SOUND_DIR.path_join("%s.%s" % [String(event), extension])
			if ResourceLoader.exists(path):
				_streams[event] = load(path) as AudioStream
				break
	return _streams.get(event, null) as AudioStream


## Sets the sound for [param event] (null removes it).
static func set_stream(event: StringName, stream: AudioStream) -> void:
	_looked_up[event] = true
	if stream == null:
		_streams.erase(event)
	else:
		_streams[event] = stream


## How many times [method play] has counted the event since the last [method reset].
static func get_play_count(event: StringName) -> int:
	return int(_counts.get(event, 0))


## Forgets the set sounds, the counters and the timings, and removes the mute.
static func reset() -> void:
	_streams.clear()
	_looked_up.clear()
	_counts.clear()
	_last_msec.clear()
	muted = false


## Connects a button to its sounds: hovering or focusing it plays "hover" and pressing it plays "click".
## Ignores a button that is already connected.
static func hook_button(button: BaseButton) -> void:
	if button.has_meta(HOOKED_META):
		return
	button.set_meta(HOOKED_META, true)
	button.mouse_entered.connect(func() -> void:
		if not button.disabled:
			play(HOVER))
	button.focus_entered.connect(func() -> void:
		if not button.disabled:
			play(HOVER))
	button.pressed.connect(func() -> void: play(CLICK))


## Connects a slider: each value change makes a "tick".
static func hook_slider(slider: Slider) -> void:
	if slider.has_meta(HOOKED_META):
		return
	slider.set_meta(HOOKED_META, true)
	slider.value_changed.connect(func(_value: float) -> void: play(TICK))


## Connects all the buttons and sliders under [param root] (those that exist right now).
static func hook_all(root: Node) -> void:
	for node: Node in root.find_children("*", "BaseButton", true, false):
		hook_button(node as BaseButton)
	for node: Node in root.find_children("*", "Slider", true, false):
		hook_slider(node as Slider)
