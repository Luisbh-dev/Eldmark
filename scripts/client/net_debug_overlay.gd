class_name NetDebugOverlay
extends CanvasLayer
## Client network debugging (docs/networking.md, section 13; TEC-10).
## [br][br]
## [b]F3[/b] ([code]toggle_debug[/code]) shows or hides the text panel (top right):
## [codeblock]
## ENet RTT (without the network simulator) and in ticks, ENet loss, upload and download KB/s
## input_margin (last, minimum of the TickSync window) and target margin
## TickSync adjustments and corrections per minute, substitutions
## last and max correction, ticks simulated again
## interpolation delay, jitter, visible entities and average bytes per snapshot
## [/codeblock]
## On the networked client, F3 toggles at once this panel and the sandbox HUD's debug panel
## ([method HUD.set_debug_visible]), which is seen on the left: [OnlineMain] starts with both
## hidden and both respond to the same key. This panel does not mark the event as handled.
## [br][br]
## [b]F4[/b] ([code]toggle_net_ghost[/code]) turns the visual aid on or off: a translucent ghost
## at the position of the last own state the server sent (the difference from the character is how
## far ahead the prediction runs) and a mark at each uninterpolated sample of the remote
## players (from oldest to newest; they are interpolated between).
## [br][br]
## Read-only: it never modifies the simulation. The counters are sampled ([constant SAMPLE_INTERVAL])
## even if the panel is hidden, so that there is already history when it is opened; per-minute rates use a
## window of up to [constant RATE_WINDOW_SECONDS] s and are not shown until there are
## [constant MIN_RATE_SECONDS] s of data.

## Seconds between two samplings of the counters (and text refreshes).
const SAMPLE_INTERVAL: float = 0.25
## Window (s) of the per-minute rates, of the KB/s and of the average bytes per snapshot.
const RATE_WINDOW_SECONDS: float = 60.0
const THROUGHPUT_WINDOW_SECONDS: float = 2.0
const SNAPSHOT_SIZE_WINDOW_SECONDS: float = 4.0
## Minimum data (s) to show a per-minute rate.
const MIN_RATE_SECONDS: float = 10.0
## Ghost capsule (the character's) and radius of the marks (m).
const GHOST_RADIUS: float = 0.4
const GHOST_HEIGHT: float = 1.8
const MARK_RADIUS: float = 0.07
## Height (m) above the feet at which a sample's mark is drawn.
const MARK_HEIGHT: float = 0.9
const GHOST_COLOR: Color = Color(0.3, 0.85, 1.0, 0.32)
const MARK_COLOR: Color = Color(1.0, 0.85, 0.2, 1.0)
const TEXT_NO_VALUE: String = "—"

var _client: NetClient = null
var _samples: Array[_Sample] = []
var _sample_time_left: float = 0.0
var _text: String = ""
var _ghost_enabled: bool = false
var _ghost: MeshInstance3D = null
var _marks: MultiMeshInstance3D = null
var _mark_positions: PackedVector3Array = PackedVector3Array()

@onready var _panel: PanelContainer = $Panel
@onready var _label: Label = $Panel/Label


## A reading of the counters at an instant.
class _Sample:
	var time: float = 0.0
	var adjustments: int = 0
	var corrections: int = 0
	var substitutions: int = 0
	var snapshots: int = 0
	var wire_in: int = 0
	var wire_out: int = 0
	var app_in: int = 0


func _ready() -> void:
	# A text panel must not move with physics interpolation or swallow the mouse.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	InputBindings.ensure_defaults()
	_panel.visible = false
	_create_ghost()
	_create_marks()
	_set_ghost_enabled(false)
	refresh()


## Connects the debugging to the network client [param client]. It can be called before or after
## adding the node to the tree, and repeated with another client (it starts from scratch).
func bind(client: NetClient) -> void:
	_client = client
	_samples.clear()
	_sample_time_left = 0.0
	if is_node_ready():
		refresh()


func _input(event: InputEvent) -> void:
	if InputMap.has_action(&"toggle_debug") and event.is_action_pressed(&"toggle_debug"):
		set_panel_visible(not _panel.visible)
	elif InputMap.has_action(&"toggle_net_ghost") and event.is_action_pressed(&"toggle_net_ghost"):
		_set_ghost_enabled(not _ghost_enabled)


func _process(delta: float) -> void:
	_sample_time_left -= delta
	if _sample_time_left <= 0.0:
		_sample_time_left = SAMPLE_INTERVAL
		refresh()
	if _ghost_enabled:
		update_ghost()


## Shows or hides the text panel.
func set_panel_visible(visible_now: bool) -> void:
	_panel.visible = visible_now
	if visible_now:
		refresh()


func is_panel_visible() -> bool:
	return _panel.visible


## Turns the ghost and the sample marks on or off (F4).
func set_ghost_visible(visible_now: bool) -> void:
	_set_ghost_enabled(visible_now)


func is_ghost_visible() -> bool:
	return _ghost_enabled


## Translucent ghost of the server's last own state.
func get_ghost() -> MeshInstance3D:
	return _ghost


## Marks of the remotes' uninterpolated samples (one instance per sample).
func get_sample_marks() -> MultiMeshInstance3D:
	return _marks


## Positions (without the drawing height) of the remotes' samples that were marked in the last
## ghost update.
func get_mark_positions() -> PackedVector3Array:
	return _mark_positions


## Panel text as it was shown in the last refresh.
func get_text() -> String:
	return _text


## Reads the client's counters and rebuilds the text. [param now_seconds] is the instant of the
## reading (by default, the system clock); only tests change it.
func refresh(now_seconds: float = -1.0) -> void:
	if not is_node_ready():
		return
	if now_seconds < 0.0:
		now_seconds = float(Time.get_ticks_msec()) / 1000.0
	if _client == null or not is_instance_valid(_client):
		_text = "RED · sin cliente"
	else:
		var stats: Dictionary = _client.get_stats()
		_record_sample(now_seconds, stats)
		_text = _build_text(stats)
	_label.text = _text


# --- Sampling and rates -----------------------------------------------------------------------

func _record_sample(now_seconds: float, stats: Dictionary) -> void:
	var sample := _Sample.new()
	sample.time = now_seconds
	sample.adjustments = int(stats["tick_sync_adjustments"])
	sample.corrections = int(stats["corrections"])
	sample.substitutions = int(stats["substitutions_total"])
	sample.snapshots = int(stats["snapshots"])
	var transport: NetTransport = _client.get_transport()
	if transport != null and is_instance_valid(transport):
		var bytes: Dictionary = transport.get_byte_counters()
		sample.wire_in = int(bytes["wire_in"])
		sample.wire_out = int(bytes["wire_out"])
		sample.app_in = int(bytes["app_in"])
	_samples.append(sample)
	while _samples.size() > 1 and now_seconds - _samples[0].time > RATE_WINDOW_SECONDS:
		_samples.pop_front()


# First sample of the window of [param seconds] s ending at the last one (or the oldest there
# is if there is not that much history yet).
func _window_start(seconds: float) -> _Sample:
	var last: _Sample = _samples[_samples.size() - 1]
	for sample: _Sample in _samples:
		if last.time - sample.time <= seconds:
			return sample
	return last


# "Amount per minute" text of a counter, or TEXT_NO_VALUE if there are fewer than MIN_RATE_SECONDS s
# of history.
func _per_minute(field: StringName) -> String:
	if _samples.size() < 2:
		return TEXT_NO_VALUE
	var first: _Sample = _samples[0]
	var last: _Sample = _samples[_samples.size() - 1]
	var elapsed: float = last.time - first.time
	if elapsed < MIN_RATE_SECONDS:
		return TEXT_NO_VALUE
	return "%.1f/min" % (float(int(last.get(field)) - int(first.get(field))) * 60.0 / elapsed)


# KB/s of the bytes counter [param field] over the last THROUGHPUT_WINDOW_SECONDS s.
func _kilobytes_per_second(field: StringName) -> String:
	if _samples.size() < 2:
		return TEXT_NO_VALUE
	var last: _Sample = _samples[_samples.size() - 1]
	var first: _Sample = _window_start(THROUGHPUT_WINDOW_SECONDS)
	var elapsed: float = last.time - first.time
	if elapsed <= 0.0:
		return TEXT_NO_VALUE
	return "%.1f KB/s" % (float(int(last.get(field)) - int(first.get(field))) / elapsed / 1024.0)


# Application bytes received per snapshot (includes the few reliable messages, so it is an
# upper approximation) over the last SNAPSHOT_SIZE_WINDOW_SECONDS s.
func _bytes_per_snapshot() -> String:
	if _samples.size() < 2:
		return TEXT_NO_VALUE
	var last: _Sample = _samples[_samples.size() - 1]
	var first: _Sample = _window_start(SNAPSHOT_SIZE_WINDOW_SECONDS)
	var snapshots: int = last.snapshots - first.snapshots
	if snapshots <= 0:
		return TEXT_NO_VALUE
	return "%d B" % roundi(float(last.app_in - first.app_in) / float(snapshots))


# --- Text -------------------------------------------------------------------------------------

func _build_text(stats: Dictionary) -> String:
	var ticks_per_second: float = float(Engine.physics_ticks_per_second)
	var transport: NetTransport = _client.get_transport()
	var rtt_text: String = TEXT_NO_VALUE
	var loss_text: String = TEXT_NO_VALUE
	if transport != null and is_instance_valid(transport):
		rtt_text = "%d ms" % roundi(transport.get_rtt_ms(NetClient.SERVER_PEER_ID))
		loss_text = "%.1f %%" % (transport.get_packet_loss(NetClient.SERVER_PEER_ID) * 100.0)
	var margin: int = int(stats["last_input_margin"])
	var window_min: int = int(stats["window_min"])
	var delay: float = float(stats["delay_ticks"])
	var jitter: float = float(stats["jitter_ticks"])
	var ahead: int = int(stats["predicted_tick"]) - int(stats["server_tick"])
	var visible_remotes: int = 0
	var known_remotes: int = 0
	for view: RemotePlayerView in _client.get_remote_world().get_views():
		known_remotes += 1
		var body: PlayerCharacter = view.get_body()
		if is_instance_valid(body) and body.visible:
			visible_remotes += 1
	var lines: PackedStringArray = [
		"RED · F3 oculta · F4 fantasma %s" % ("(sí)" if _ghost_enabled else "(no)"),
		"RTT ENet: %s (sin simulador) · al entrar: %d ticks" % [rtt_text, int(stats["rtt_ticks"])],
		"Por delante del servidor: %d ticks · pérdida ENet: %s" % [ahead, loss_text],
		"Subida: %s · Bajada: %s" % [_kilobytes_per_second(&"wire_out"),
				_kilobytes_per_second(&"wire_in")],
		"input_margin: %s · ventana: %s · objetivo: %d" % [_margin_text(margin),
				_margin_text(window_min), int(stats["target_margin"])],
		"Ajustes de TickSync: %d (%s) · resincronizaciones: %d" % [
			int(stats["tick_sync_adjustments"]), _per_minute(&"adjustments"),
			int(stats["resyncs"])],
		"Sustituciones: %d (%s)" % [int(stats["substitutions_total"]),
				_per_minute(&"substitutions")],
		"Correcciones: %d (%s) · última %s · máxima %s" % [int(stats["corrections"]),
				_per_minute(&"corrections"), _centimeters(float(stats["last_correction"])),
				_centimeters(float(stats["max_correction"]))],
		"Ticks vueltos a simular: %d" % int(stats["resimulated_ticks"]),
		"Interpolación: retardo %.1f ticks (%d ms) · jitter %.1f ticks (%d ms)" % [
			delay, roundi(delay * 1000.0 / ticks_per_second), jitter,
			roundi(jitter * 1000.0 / ticks_per_second)],
		"Entidades visibles: %d de %d · bytes por snapshot: %s" % [visible_remotes,
				known_remotes, _bytes_per_snapshot()],
	]
	return "\n".join(lines)


func _margin_text(margin: int) -> String:
	return TEXT_NO_VALUE if margin == NetProtocol.NO_MARGIN else str(margin)


func _centimeters(meters: float) -> String:
	return "%.1f cm" % (meters * 100.0)


# --- Ghost and marks (F4) ---------------------------------------------------------------------

func _create_ghost() -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = GHOST_RADIUS
	mesh.height = GHOST_HEIGHT
	var material := StandardMaterial3D.new()
	material.albedo_color = GHOST_COLOR
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = material
	_ghost = MeshInstance3D.new()
	_ghost.name = "ServerGhost"
	_ghost.mesh = mesh
	_ghost.top_level = true
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_ghost)


func _create_marks() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = MARK_RADIUS
	mesh.height = MARK_RADIUS * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var material := StandardMaterial3D.new()
	material.albedo_color = MARK_COLOR
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = 0
	_marks = MultiMeshInstance3D.new()
	_marks.name = "SampleMarks"
	_marks.multimesh = multimesh
	_marks.top_level = true
	_marks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marks.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_marks)


func _set_ghost_enabled(enabled: bool) -> void:
	_ghost_enabled = enabled
	_ghost.visible = enabled
	_marks.visible = enabled
	if enabled:
		update_ghost()


## Places the ghost at the server's last own state and a mark at each sample of each
## remote. It is rebuilt every frame while F4 is on.
func update_ghost() -> void:
	if _client == null or not is_instance_valid(_client):
		_ghost.visible = false
		_mark_positions.clear()
		_marks.multimesh.instance_count = 0
		return
	var server_state: PlayerState = _client.get_last_server_state()
	_ghost.visible = server_state != null
	if server_state != null:
		_ghost.global_position = server_state.position + Vector3(0.0, GHOST_HEIGHT * 0.5, 0.0)
	_mark_positions.clear()
	for view: RemotePlayerView in _client.get_remote_world().get_views():
		_mark_positions.append_array(view.get_sample_positions())
	var multimesh: MultiMesh = _marks.multimesh
	if multimesh.instance_count != _mark_positions.size():
		multimesh.instance_count = _mark_positions.size()
	for i: int in _mark_positions.size():
		multimesh.set_instance_transform(i,
				Transform3D(Basis.IDENTITY, _mark_positions[i] + Vector3(0.0, MARK_HEIGHT, 0.0)))
