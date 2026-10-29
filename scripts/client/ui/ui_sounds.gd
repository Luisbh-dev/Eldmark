class_name UISounds
extends RefCounted
## Ganchos de sonido de la interfaz (UI-09): pasar el ratón, pulsar, confirmar, cancelar, abrir y
## cerrar una ventana, error y el «tic» de un deslizador. Suenan por el bus [constant AudioBuses.UI]
## a través del [AudioDirector].
## [br][br]
## Todavía no hay sonidos reales ([code]assets/audio/ui/[/code] está vacío): [method play] busca
## [code]assets/audio/ui/<evento>.ogg[/code] (o [code].wav[/code]) la primera vez que se pide cada
## evento y, si no existe, no suena nada pero el gancho funciona igual (se cuenta con
## [method get_play_count], que usan las pruebas). Cuando lleguen los de Kenney (ART-11, CC0)
## bastará con dejarlos con esos nombres. [method set_stream] fija uno a mano (pruebas, o un tema
## sonoro distinto).
## [br][br]
## [method hook_button] y [method hook_all] conectan los botones y los deslizadores de un árbol de
## controles con sus sonidos; los componentes comunes ([UIIconSlot], [UIConfirmDialog],
## [UIWindow]) llaman a [method play] por su cuenta.
## [br][br]
## Solo cliente.

const HOVER: StringName = &"hover"
const CLICK: StringName = &"click"
const CONFIRM: StringName = &"confirm"
const CANCEL: StringName = &"cancel"
const OPEN: StringName = &"open"
const CLOSE: StringName = &"close"
const ERROR: StringName = &"error"
const TICK: StringName = &"tick"

## Todos los eventos de sonido de la interfaz.
const EVENTS: Array[StringName] = [HOVER, CLICK, CONFIRM, CANCEL, OPEN, CLOSE, ERROR, TICK]
## Carpeta de los sonidos y extensiones que se prueban, por orden.
const SOUND_DIR: String = "res://assets/audio/ui"
const EXTENSIONS: Array[String] = ["ogg", "wav"]
## Volumen (dB) de cada evento; los que no figuran, 0. Pasar el ratón y el tic son discretos.
const VOLUMES_DB: Dictionary = {HOVER: -9.0, TICK: -11.0}
## Milisegundos mínimos entre dos reproducciones del mismo evento (los que no figuran, sin límite):
## recorrer una lista no debe sonar como una metralleta.
const MIN_REPEAT_MSEC: Dictionary = {HOVER: 60, TICK: 45}
const HOOKED_META: StringName = &"ui_sounds_hooked"

## Silencia todos los ganchos (ajuste del jugador o pruebas).
static var muted: bool = false

# Evento -> AudioStream (null si no hay sonido para él).
static var _streams: Dictionary = {}
static var _looked_up: Dictionary = {}
static var _counts: Dictionary = {}
static var _last_msec: Dictionary = {}


## Pide el sonido de [param event]. Devuelve true si cuenta como reproducido (no se silenció ni se
## frenó por repetirse demasiado pronto); suena de verdad si hay un [AudioDirector] y un sonido para
## el evento.
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


## Sonido de [param event]: el fijado con [method set_stream] o, si no, el de
## [code]assets/audio/ui/[/code] (null si no hay ninguno).
static func get_stream(event: StringName) -> AudioStream:
	if not _looked_up.has(event):
		_looked_up[event] = true
		for extension: String in EXTENSIONS:
			var path: String = SOUND_DIR.path_join("%s.%s" % [String(event), extension])
			if ResourceLoader.exists(path):
				_streams[event] = load(path) as AudioStream
				break
	return _streams.get(event, null) as AudioStream


## Fija el sonido de [param event] (null lo quita).
static func set_stream(event: StringName, stream: AudioStream) -> void:
	_looked_up[event] = true
	if stream == null:
		_streams.erase(event)
	else:
		_streams[event] = stream


## Cuántas veces ha contado [method play] el evento desde el último [method reset].
static func get_play_count(event: StringName) -> int:
	return int(_counts.get(event, 0))


## Olvida los sonidos fijados, los contadores y los tiempos, y quita el silencio.
static func reset() -> void:
	_streams.clear()
	_looked_up.clear()
	_counts.clear()
	_last_msec.clear()
	muted = false


## Conecta un botón con sus sonidos: pasar el ratón o enfocarlo suena a «hover» y pulsarlo a
## «click». Ignora un botón que ya está conectado.
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


## Conecta un deslizador: cada cambio de valor hace un «tic».
static func hook_slider(slider: Slider) -> void:
	if slider.has_meta(HOOKED_META):
		return
	slider.set_meta(HOOKED_META, true)
	slider.value_changed.connect(func(_value: float) -> void: play(TICK))


## Conecta todos los botones y deslizadores bajo [param root] (los que haya ahora).
static func hook_all(root: Node) -> void:
	for node: Node in root.find_children("*", "BaseButton", true, false):
		hook_button(node as BaseButton)
	for node: Node in root.find_children("*", "Slider", true, false):
		hook_slider(node as Slider)
